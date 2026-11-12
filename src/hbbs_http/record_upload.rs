use crate::hbbs_http::{create_http_client_with_url, create_http_client_with_url_strict};
use bytes::Bytes;
use hbb_common::{bail, config::Config, lazy_static, log, ResultType};
use reqwest::blocking::{Body, Client};
use scrap::record::RecordState;
use serde::Serialize;
use serde_json::Map;
use std::{
    fs::File,
    io::{prelude::*, SeekFrom},
    sync::{mpsc::Receiver, Arc, Mutex},
    time::{Duration, Instant},
};

const MAX_HEADER_LEN: usize = 1024;
const SHOULD_SEND_TIME: Duration = Duration::from_secs(1);
const SHOULD_SEND_SIZE: u64 = 1024 * 1024;

lazy_static::lazy_static! {
    static ref ENABLE: Arc<Mutex<bool>> = Default::default();
}

/// TRMM Desktop: session recording upload to the Tactical RMM server
/// (recordings app). Set by `--record-config` on managed hosts and by the
/// quick support after it creates its session.
pub const OPTION_TRMM_RECORD_URL: &str = "trmm-record-url";
pub const OPTION_TRMM_RECORD_TOKEN: &str = "trmm-record-token";
const TRMM_TOKEN_HEADER: &str = "X-TRMM-Record-Token";

/// (upload url, token) when TRMM recording is configured
pub fn trmm_target() -> Option<(String, String)> {
    let url = Config::get_option(OPTION_TRMM_RECORD_URL);
    let token = Config::get_option(OPTION_TRMM_RECORD_TOKEN);
    if valid_trmm_target(&url, &token) {
        Some((url, token))
    } else {
        None
    }
}

pub fn valid_trmm_target(url: &str, token: &str) -> bool {
    url.starts_with("https://")
        && url.len() < 512
        && !url.chars().any(|c| c.is_whitespace() || c.is_control())
        && (16..=128).contains(&token.len())
        && token
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

pub fn is_enable() -> bool {
    ENABLE.lock().unwrap().clone() || trmm_target().is_some()
}

pub fn run(rx: Receiver<RecordState>) {
    std::thread::spawn(move || {
        let (url, token, client) = match trmm_target() {
            Some((url, token)) => match create_http_client_with_url_strict(&url) {
                Ok(client) => (url, Some(token), client),
                Err(e) => {
                    log::error!("record upload: {}", e);
                    return;
                }
            },
            None => {
                let api_server = crate::get_api_server(
                    Config::get_option("api-server"),
                    Config::get_option("custom-rendezvous-server"),
                );
                // This URL is used for TLS connectivity testing and fallback detection.
                let login_option_url = format!("{}/api/login-options", &api_server);
                let client = create_http_client_with_url(&login_option_url);
                (format!("{}/api/record", api_server), None, client)
            }
        };
        let mut uploader = RecordUploader {
            client,
            url,
            token,
            filepath: Default::default(),
            filename: Default::default(),
            upload_size: Default::default(),
            running: Default::default(),
            last_send: Instant::now(),
        };
        loop {
            if let Err(e) = match rx.recv() {
                Ok(state) => match state {
                    RecordState::NewFile(filepath) => uploader.handle_new_file(filepath),
                    RecordState::NewFrame => {
                        if uploader.running {
                            uploader.handle_frame(false)
                        } else {
                            Ok(())
                        }
                    }
                    RecordState::WriteTail => {
                        if uploader.running {
                            uploader.handle_tail()
                        } else {
                            Ok(())
                        }
                    }
                    RecordState::RemoveFile => {
                        if uploader.running {
                            uploader.handle_remove()
                        } else {
                            Ok(())
                        }
                    }
                },
                Err(e) => {
                    log::trace!("upload thread stop: {}", e);
                    break;
                }
            } {
                uploader.running = false;
                log::error!("upload stop: {}", e);
            }
        }
    });
}

struct RecordUploader {
    client: Client,
    // full upload url ({api-server}/api/record or the TRMM recordings url)
    url: String,
    // TRMM: token of this computer / quick support session
    token: Option<String>,
    filepath: String,
    filename: String,
    upload_size: u64,
    running: bool,
    last_send: Instant,
}
impl RecordUploader {
    fn send<Q, B>(&self, query: &Q, body: B) -> ResultType<()>
    where
        Q: Serialize + ?Sized,
        B: Into<Body>,
    {
        let mut req = self.client.post(&self.url).query(query).body(body);
        if let Some(token) = &self.token {
            req = req.header(TRMM_TOKEN_HEADER, token);
        }
        match req.send() {
            Ok(resp) => {
                let status = resp.status();
                if let Ok(m) = resp.json::<Map<String, serde_json::Value>>() {
                    if let Some(e) = m.get("error") {
                        bail!(e.to_string());
                    }
                }
                if self.token.is_some() && !status.is_success() {
                    bail!("server answered {}", status);
                }
                Ok(())
            }
            Err(e) => bail!(e.to_string()),
        }
    }

    fn handle_new_file(&mut self, filepath: String) -> ResultType<()> {
        match std::path::PathBuf::from(&filepath).file_name() {
            Some(filename) => match filename.to_owned().into_string() {
                Ok(filename) => {
                    self.filename = filename.clone();
                    self.filepath = filepath.clone();
                    self.upload_size = 0;
                    self.running = true;
                    self.last_send = Instant::now();
                    self.send(&[("type", "new"), ("file", &filename)], Bytes::new())?;
                    Ok(())
                }
                Err(_) => bail!("can't parse filename:{:?}", filename),
            },
            None => bail!("can't parse filepath:{}", filepath),
        }
    }

    fn handle_frame(&mut self, flush: bool) -> ResultType<()> {
        if !flush && self.last_send.elapsed() < SHOULD_SEND_TIME {
            return Ok(());
        }
        match File::open(&self.filepath) {
            Ok(mut file) => match file.metadata() {
                Ok(m) => {
                    let len = m.len();
                    if len <= self.upload_size {
                        return Ok(());
                    }
                    if !flush && len - self.upload_size < SHOULD_SEND_SIZE {
                        return Ok(());
                    }
                    let mut buf = Vec::new();
                    match file.seek(SeekFrom::Start(self.upload_size)) {
                        Ok(_) => match file.read_to_end(&mut buf) {
                            Ok(length) => {
                                self.send(
                                    &[
                                        ("type", "part"),
                                        ("file", &self.filename),
                                        ("offset", &self.upload_size.to_string()),
                                        ("length", &length.to_string()),
                                    ],
                                    buf,
                                )?;
                                self.upload_size = len;
                                self.last_send = Instant::now();
                                Ok(())
                            }
                            Err(e) => bail!(e.to_string()),
                        },
                        Err(e) => bail!(e.to_string()),
                    }
                }
                Err(e) => bail!(e.to_string()),
            },
            Err(e) => bail!(e.to_string()),
        }
    }

    fn handle_tail(&mut self) -> ResultType<()> {
        self.handle_frame(true)?;
        match File::open(&self.filepath) {
            Ok(mut file) => {
                let mut buf = vec![0u8; MAX_HEADER_LEN];
                match file.read(&mut buf) {
                    Ok(length) => {
                        buf.truncate(length);
                        self.send(
                            &[
                                ("type", "tail"),
                                ("file", &self.filename),
                                ("offset", "0"),
                                ("length", &length.to_string()),
                            ],
                            buf,
                        )?;
                        log::info!("upload success, file: {}", self.filename);
                        if self.token.is_some() {
                            // TRMM: the server keeps the recording, no local copy
                            if let Err(e) = std::fs::remove_file(&self.filepath) {
                                log::error!("unable to delete {}: {}", self.filepath, e);
                            }
                        }
                        Ok(())
                    }
                    Err(e) => bail!(e.to_string()),
                }
            }
            Err(e) => bail!(e.to_string()),
        }
    }

    fn handle_remove(&mut self) -> ResultType<()> {
        self.send(
            &[("type", "remove"), ("file", &self.filename)],
            Bytes::new(),
        )?;
        Ok(())
    }
}

/// TRMM managed host, at service start: recordings left behind (no network
/// or the service stopped during a session) are uploaded whole, then deleted.
pub fn upload_leftovers(dir: String) {
    std::thread::spawn(move || {
        // let the network come up after boot
        std::thread::sleep(Duration::from_secs(60));
        let Some((url, token)) = trmm_target() else {
            return;
        };
        let client = match create_http_client_with_url_strict(&url) {
            Ok(c) => c,
            Err(e) => {
                log::error!("record upload: {}", e);
                return;
            }
        };
        let Ok(entries) = std::fs::read_dir(&dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();
            if !name.starts_with("incoming_")
                || !(name.ends_with(".webm") || name.ends_with(".mp4"))
            {
                continue;
            }
            let old = entry
                .metadata()
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.elapsed().ok())
                .map(|e| e > Duration::from_secs(60))
                .unwrap_or(false);
            if !old {
                continue;
            }
            let mut uploader = RecordUploader {
                client: client.clone(),
                url: url.clone(),
                token: Some(token.clone()),
                filepath: Default::default(),
                filename: Default::default(),
                upload_size: 0,
                running: false,
                last_send: Instant::now(),
            };
            let result = uploader
                .handle_new_file(path.to_string_lossy().to_string())
                .and_then(|_| uploader.upload_whole())
                .and_then(|_| uploader.handle_tail());
            match result {
                Ok(_) => log::info!("leftover recording uploaded: {}", name),
                Err(e) => log::error!("leftover recording {}: {}", name, e),
            }
        }
    });
}

impl RecordUploader {
    // whole file in parts of at most 8 MB
    fn upload_whole(&mut self) -> ResultType<()> {
        const PART: u64 = 8 * 1024 * 1024;
        let mut file = File::open(&self.filepath)?;
        let len = file.metadata()?.len();
        while self.upload_size < len {
            let size = PART.min(len - self.upload_size);
            let mut buf = vec![0u8; size as usize];
            file.seek(SeekFrom::Start(self.upload_size))?;
            file.read_exact(&mut buf)?;
            self.send(
                &[
                    ("type", "part"),
                    ("file", &self.filename),
                    ("offset", &self.upload_size.to_string()),
                    ("length", &size.to_string()),
                ],
                buf,
            )?;
            self.upload_size += size;
        }
        Ok(())
    }
}
