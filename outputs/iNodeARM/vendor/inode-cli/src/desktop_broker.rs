//! Minimal privileged network setup. No TLS, credentials or filesystem socket.
use anyhow::{Context, Result, ensure};
use inode_cli::platform::{self, Platform, Routes, SystemExecutor};
use serde::{Deserialize, Serialize};
use std::{io::{BufRead, BufReader, Read, Write}, net::{IpAddr, Ipv4Addr}, os::{fd::{AsRawFd, RawFd}, unix::net::UnixStream}, sync::{Mutex, OnceLock}};
static CHANNEL: OnceLock<Mutex<Option<(UnixStream,libc::pid_t)>>> = OnceLock::new();
static TERMINATING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
extern "C" fn terminate(_:libc::c_int) {
    TERMINATING.store(true,std::sync::atomic::Ordering::Relaxed);
}
#[derive(Serialize,Deserialize)]
struct Setup { address:Ipv4Addr, routes:Vec<ipnet::Ipv4Net>, gateways:Vec<IpAddr>, mtu:u16 }
fn validate(s:&Setup)->Result<()> {
    ensure!(!s.address.is_unspecified()&&!s.address.is_multicast()&&!s.address.is_loopback(),"Invalid tunnel address");
    ensure!((576..=1500).contains(&s.mtu),"Invalid tunnel MTU");
    ensure!(!s.routes.is_empty()&&s.routes.len()<=256,"Invalid route count");
    platform::validate_routes(&s.routes,&s.gateways)
}
pub fn bootstrap(uid:u32)->Result<()> {
    if unsafe{libc::geteuid()}!=0 { return Ok(()) }
    let (parent,child)=UnixStream::pair()?;
    // Before the Tokio runtime starts, the process has no worker threads.
    let pid=unsafe{libc::fork()};ensure!(pid>=0,"Cannot start network helper");
    if pid==0 {
        drop(parent);
        // launchd stops the process group during upgrade/uninstall. Let the
        // privileged child drop Routes instead of dying with installed routes.
        unsafe {
            let mut action:libc::sigaction=std::mem::zeroed();
            action.sa_sigaction=terminate as *const () as usize;
            libc::sigemptyset(&mut action.sa_mask);
            libc::sigaction(libc::SIGTERM,&action,std::ptr::null_mut());
            libc::sigaction(libc::SIGINT,&action,std::ptr::null_mut());
        }
        let result=serve(child);
        if result.is_err(){eprintln!("Network setup helper ended with an error");}
        unsafe{libc::_exit(if result.is_ok(){0}else{1})}
    }
    drop(child);
    unsafe {
        let user=libc::getpwuid(uid);ensure!(!user.is_null(),"Unknown desktop user");
        let gid=(*user).pw_gid;
        ensure!(libc::initgroups((*user).pw_name,gid.try_into()?)==0,"Cannot drop supplementary groups");
        ensure!(libc::setgid(gid)==0&&libc::setuid(uid)==0,"Cannot drop administrator privileges");
        ensure!(libc::getuid()==uid&&libc::geteuid()==uid,"Privilege drop failed");
        ensure!(libc::setuid(0)!=0,"Administrator privileges remain recoverable");
    }
    CHANNEL.set(Mutex::new(Some((parent,pid)))).map_err(|_|anyhow::anyhow!("Duplicate helper"))?;
    Ok(())
}
fn serve(mut channel:UnixStream)->Result<()> {
    channel.set_read_timeout(Some(std::time::Duration::from_secs(1)))?;
    let mut reader=BufReader::new(channel.try_clone()?);
    let mut bytes=Vec::new();
    // Captcha/SMS entry may take minutes. Poll for shutdown without imposing
    // an authentication deadline, preserving partial frames across timeouts.
    loop {
        if TERMINATING.load(std::sync::atomic::Ordering::Relaxed) {return Ok(())}
        ensure!(bytes.len()<=65536,"Setup request too large");
        let remaining=(65537-bytes.len()) as u64;
        match reader.by_ref().take(remaining).read_until(b'\n',&mut bytes) {
            Ok(0)=>return Ok(()),
            Ok(_) if bytes.last()==Some(&b'\n')=>break,
            Ok(_)=>ensure!(bytes.len()<=65536,"Setup request too large"),
            Err(e) if matches!(e.kind(),std::io::ErrorKind::WouldBlock|std::io::ErrorKind::TimedOut|std::io::ErrorKind::Interrupted)=>{},
            Err(e)=>return Err(e.into()),
        }
    }
    ensure!(bytes.len()<=65536,"Setup request too large");
    let setup:Setup=serde_json::from_slice(&bytes)?;validate(&setup)?;
    ensure!(!TERMINATING.load(std::sync::atomic::Ordering::Relaxed),"Network helper is stopping");
    let device=tun_rs::DeviceBuilder::new().ipv4(setup.address,32,None).mtu(setup.mtu).build_sync()?;
    let name=device.name()?;
    let _routes=Routes::install(Platform::Macos,&name,&setup.routes,SystemExecutor)?;
    send_fd(&channel,device.as_raw_fd())?;
    // Only EOF or an explicit stop is needed after this one setup operation.
    channel.set_read_timeout(Some(std::time::Duration::from_secs(1)))?;
    let mut stop=[0u8;1];
    while !TERMINATING.load(std::sync::atomic::Ordering::Relaxed) {
        match channel.read(&mut stop) {
            Err(e) if matches!(e.kind(),std::io::ErrorKind::WouldBlock|std::io::ErrorKind::TimedOut|std::io::ErrorKind::Interrupted)=>{},
            _=>break,
        }
    }
    Ok(())
}
pub struct Lease { channel:UnixStream,pid:libc::pid_t }
impl Drop for Lease {fn drop(&mut self){let _=self.channel.write_all(b"x");let _=self.channel.shutdown(std::net::Shutdown::Both);unsafe{libc::waitpid(self.pid,std::ptr::null_mut(),0);}}}
pub fn configure(address:Ipv4Addr,routes:Vec<ipnet::Ipv4Net>,gateways:Vec<IpAddr>,mtu:u16)->Result<(tun_rs::AsyncDevice,Lease)> {
    let setup=Setup{address,routes,gateways,mtu};validate(&setup)?;
    let (mut channel,pid)=CHANNEL.get().context("Network setup requires administrator authorization")?.lock().unwrap().take().context("Network helper already used")?;
    let lease=Lease{channel:channel.try_clone()?,pid};
    channel.set_read_timeout(Some(std::time::Duration::from_secs(20)))?;
    let mut bytes=serde_json::to_vec(&setup)?;bytes.push(b'\n');channel.write_all(&bytes)?;
    let fd=receive_fd(&channel)?;
    // SCM_RIGHTS gives us an owned descriptor of the helper-created utun.
    let device=unsafe{tun_rs::AsyncDevice::from_fd(fd)}?;
    Ok((device,lease))
}
fn send_fd(channel:&UnixStream,fd:RawFd)->Result<()> {
    unsafe {
        let mut control=[0usize;8];let mut byte=1u8;
        let mut iov=libc::iovec{iov_base:(&mut byte as *mut u8).cast(),iov_len:1};
        let mut msg:libc::msghdr=std::mem::zeroed();msg.msg_iov=&mut iov;msg.msg_iovlen=1;
        msg.msg_control=control.as_mut_ptr().cast();msg.msg_controllen=libc::CMSG_SPACE(std::mem::size_of::<RawFd>() as u32);
        let cmsg=libc::CMSG_FIRSTHDR(&msg);ensure!(!cmsg.is_null(),"Missing control header");
        (*cmsg).cmsg_level=libc::SOL_SOCKET;(*cmsg).cmsg_type=libc::SCM_RIGHTS;
        (*cmsg).cmsg_len=libc::CMSG_LEN(std::mem::size_of::<RawFd>() as u32);
        std::ptr::write_unaligned(libc::CMSG_DATA(cmsg).cast::<RawFd>(),fd);
        ensure!(libc::sendmsg(channel.as_raw_fd(),&msg,0)==1,"Cannot transfer utun descriptor");
    } Ok(())
}
fn receive_fd(channel:&UnixStream)->Result<RawFd> {
    unsafe {
        let mut control=[0usize;8];let mut byte=0u8;
        let mut iov=libc::iovec{iov_base:(&mut byte as *mut u8).cast(),iov_len:1};
        let mut msg:libc::msghdr=std::mem::zeroed();msg.msg_iov=&mut iov;msg.msg_iovlen=1;
        msg.msg_control=control.as_mut_ptr().cast();msg.msg_controllen=std::mem::size_of_val(&control) as u32;
        ensure!(libc::recvmsg(channel.as_raw_fd(),&mut msg,0)==1,"Network helper did not return an interface");
        let cmsg=libc::CMSG_FIRSTHDR(&msg);
        ensure!(!cmsg.is_null()&&(*cmsg).cmsg_level==libc::SOL_SOCKET&&(*cmsg).cmsg_type==libc::SCM_RIGHTS&&(*cmsg).cmsg_len==libc::CMSG_LEN(std::mem::size_of::<RawFd>() as u32)&&msg.msg_flags&libc::MSG_CTRUNC==0,"Invalid interface descriptor");
        let fd=std::ptr::read_unaligned(libc::CMSG_DATA(cmsg).cast::<RawFd>());
        ensure!(fd>=0,"Invalid interface descriptor");libc::fcntl(fd,libc::F_SETFD,libc::FD_CLOEXEC);Ok(fd)
    }
}
#[cfg(test)] mod tests {
 use super::*;
 use std::time::Duration;
 #[test] fn pending_authentication_survives_idle_poll_timeout(){
   let(a,b)=UnixStream::pair().unwrap();
   let worker=std::thread::spawn(move||serve(a));
   std::thread::sleep(Duration::from_millis(1200));
   assert!(!worker.is_finished(),"helper must wait while the user enters captcha/SMS");
   drop(b);worker.join().unwrap().unwrap();
 }
 #[test] fn partial_setup_survives_poll_timeout_and_is_still_validated(){
   let(a,mut b)=UnixStream::pair().unwrap();
   let worker=std::thread::spawn(move||serve(a));
   b.write_all(b"invalid").unwrap();std::thread::sleep(Duration::from_millis(1200));
   assert!(!worker.is_finished());b.write_all(b"\n").unwrap();
   assert!(worker.join().unwrap().is_err());
 }
 #[test] fn inherited_channel_transfers_owned_descriptor(){let(a,b)=UnixStream::pair().unwrap();let(c,mut d)=UnixStream::pair().unwrap();send_fd(&a,c.as_raw_fd()).unwrap();let fd=receive_fd(&b).unwrap();use std::os::fd::FromRawFd;let mut received=unsafe{UnixStream::from_raw_fd(fd)};received.write_all(b"ok").unwrap();let mut bytes=[0;2];d.read_exact(&mut bytes).unwrap();assert_eq!(&bytes,b"ok");}
 #[test] fn setup_is_bounded_and_rejects_default_routes(){let mut s=Setup{address:"192.0.2.2".parse().unwrap(),routes:vec!["10.0.0.0/8".parse().unwrap()],gateways:vec!["198.51.100.10".parse().unwrap()],mtu:1400};validate(&s).unwrap();s.routes=vec!["0.0.0.0/0".parse().unwrap()];assert!(validate(&s).is_err());}
}
