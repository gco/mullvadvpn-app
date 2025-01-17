use crate::{
    abortable_stream::{AbortableStream, AbortableStreamHandle},
    tls_stream::TlsStream,
};
use futures::{channel::mpsc, StreamExt};
#[cfg(target_os = "android")]
use futures::{channel::oneshot, sink::SinkExt};
use http::uri::Scheme;
use hyper::{
    client::connect::dns::{GaiResolver, Name},
    service::Service,
    Uri,
};
#[cfg(target_os = "android")]
use std::os::unix::io::{AsRawFd, RawFd};
use std::{
    fmt,
    future::Future,
    io,
    net::{IpAddr, SocketAddr},
    pin::Pin,
    str::{self, FromStr},
    sync::{Arc, Mutex},
    task::{Context, Poll},
    time::Duration,
};
#[cfg(target_os = "android")]
use tokio::net::TcpSocket;

use tokio::{net::TcpStream, runtime::Handle, time::timeout};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone)]
pub struct HttpsConnectorWithSniHandle {
    tx: mpsc::UnboundedSender<()>,
}

impl HttpsConnectorWithSniHandle {
    /// Stop all streams produced by this connector
    pub fn reset(&self) {
        let _ = self.tx.unbounded_send(());
    }
}

/// A Connector for the `https` scheme.
#[derive(Clone)]
pub struct HttpsConnectorWithSni {
    inner: Arc<Mutex<HttpsConnectorWithSniInner>>,
    sni_hostname: Option<String>,
    #[cfg(target_os = "android")]
    socket_bypass_tx: Option<mpsc::Sender<SocketBypassRequest>>,
}

struct HttpsConnectorWithSniInner {
    stream_handles: Vec<AbortableStreamHandle>,
}

#[cfg(target_os = "android")]
pub type SocketBypassRequest = (RawFd, oneshot::Sender<()>);

impl HttpsConnectorWithSni {
    pub fn new(
        handle: Handle,
        sni_hostname: Option<String>,
        #[cfg(target_os = "android")] socket_bypass_tx: Option<mpsc::Sender<SocketBypassRequest>>,
    ) -> (Self, HttpsConnectorWithSniHandle) {
        let (tx, mut rx): (_, mpsc::UnboundedReceiver<()>) = mpsc::unbounded();
        let inner = Arc::new(Mutex::new(HttpsConnectorWithSniInner {
            stream_handles: vec![],
        }));

        let inner_copy = inner.clone();
        handle.spawn(async move {
            // Handle requests by `HttpsConnectorWithSniHandle`s
            while let Some(()) = rx.next().await {
                let handles = {
                    let mut inner = inner_copy.lock().unwrap();
                    std::mem::take(&mut inner.stream_handles)
                };
                for handle in handles {
                    handle.close();
                }
            }
        });

        (
            HttpsConnectorWithSni {
                inner,
                sni_hostname,
                #[cfg(target_os = "android")]
                socket_bypass_tx,
            },
            HttpsConnectorWithSniHandle { tx },
        )
    }

    #[cfg(not(target_os = "android"))]
    async fn open_socket(addr: SocketAddr) -> std::io::Result<TcpStream> {
        timeout(CONNECT_TIMEOUT, TcpStream::connect(addr))
            .await
            .map_err(|err| io::Error::new(io::ErrorKind::TimedOut, err))?
    }

    #[cfg(target_os = "android")]
    async fn open_socket(
        addr: SocketAddr,
        socket_bypass_tx: Option<mpsc::Sender<SocketBypassRequest>>,
    ) -> std::io::Result<TcpStream> {
        let socket = match addr {
            SocketAddr::V4(_) => TcpSocket::new_v4()?,
            SocketAddr::V6(_) => TcpSocket::new_v6()?,
        };

        if let Some(mut tx) = socket_bypass_tx {
            let (done_tx, done_rx) = oneshot::channel();
            let _ = tx.send((socket.as_raw_fd(), done_tx)).await;
            if let Err(_) = done_rx.await {
                log::error!("Failed to bypass socket, connection might fail");
            }
        }

        timeout(CONNECT_TIMEOUT, socket.connect(addr))
            .await
            .map_err(|err| io::Error::new(io::ErrorKind::TimedOut, err))?
    }

    async fn resolve_address(uri: &Uri) -> io::Result<SocketAddr> {
        let hostname = uri.host().ok_or(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid url, missing host",
        ))?;
        let port = uri.port_u16().unwrap_or(443);

        if let Some(addr) = hostname.parse::<IpAddr>().ok() {
            return Ok(SocketAddr::new(addr, port));
        }

        let mut addrs = GaiResolver::new()
            .call(
                Name::from_str(&hostname)
                    .map_err(|err| io::Error::new(io::ErrorKind::InvalidInput, err))?,
            )
            .await
            .map_err(|err| io::Error::new(io::ErrorKind::Other, err))?;
        let addr = addrs
            .next()
            .ok_or(io::Error::new(io::ErrorKind::Other, "Empty DNS response"))?;
        Ok(SocketAddr::new(addr.ip(), port))
    }
}

impl fmt::Debug for HttpsConnectorWithSni {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("HttpsConnectorWithSni").finish()
    }
}

impl Service<Uri> for HttpsConnectorWithSni {
    type Response = TlsStream<AbortableStream<TcpStream>>;
    type Error = io::Error;
    type Future =
        Pin<Box<dyn Future<Output = Result<Self::Response, Self::Error>> + Send + 'static>>;

    fn poll_ready(&mut self, _: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        Poll::Ready(Ok(()))
    }

    fn call(&mut self, uri: Uri) -> Self::Future {
        let sni_hostname = self
            .sni_hostname
            .clone()
            .or_else(|| uri.host().map(str::to_owned))
            .ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidInput, "invalid url, missing host")
            });
        let inner = self.inner.clone();
        #[cfg(target_os = "android")]
        let socket_bypass_tx = self.socket_bypass_tx.clone();

        let fut = async move {
            if uri.scheme() != Some(&Scheme::HTTPS) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "invalid url, not https",
                ));
            }

            let hostname = sni_hostname?;
            let addr = Self::resolve_address(&uri).await?;

            let tokio_connection = Self::open_socket(
                addr,
                #[cfg(target_os = "android")]
                socket_bypass_tx,
            )
            .await?;

            let (tcp_stream, socket_handle) = AbortableStream::new(tokio_connection);

            {
                let mut inner = inner.lock().unwrap();
                inner.stream_handles.retain(|handle| !handle.is_closed());
                inner.stream_handles.push(socket_handle);
            }

            Ok(TlsStream::connect_https(tcp_stream, &hostname).await?)
        };

        Box::pin(fut)
    }
}
