use anyhow::{Result, Context, ensure, bail};
use inode_cli::protocol::{self, Session, GatewayInfo, AuthReply};
use serde::Deserialize;
use serde_json::json;
use std::{io::{BufRead, BufReader, Write}, os::unix::{net::{UnixListener,UnixStream},fs::{PermissionsExt,MetadataExt}}, sync::{Mutex,OnceLock}, time::Duration};
use zeroize::{Zeroizing, Zeroize};
mod desktop_broker;
mod desktop_policy;
mod desktop_queries;
mod desktop_portal;
mod portal_packet;
mod portal_compat;
mod portal_reply;
use base64::Engine;
#[path="desktop_connection.rs"] mod connection;
static OUTPUT:OnceLock<Mutex<UnixStream>>=OnceLock::new();
static STOP:OnceLock<Mutex<Option<tokio::sync::oneshot::Sender<()>>>>=OnceLock::new();
static STOP_RX:OnceLock<Mutex<Option<tokio::sync::oneshot::Receiver<()>>>>=OnceLock::new();
fn event(v:serde_json::Value) { if let Some(o)=OUTPUT.get() { let mut o=o.lock().unwrap(); let _=writeln!(o,"{v}"); } }
fn stop_receiver()->tokio::sync::oneshot::Receiver<()> { STOP_RX.get().unwrap().lock().unwrap().take().unwrap() }
pub struct ConnectArgs { route:Vec<ipnet::Ipv4Net>,gateway_routes:bool,mtu:u16,reconnect_attempts:u32 }
#[derive(Deserialize)] struct Command {
    op:String, #[serde(default)] gateway:String,
    #[serde(default)] mode:String,
    #[serde(default)] domain:String, #[serde(default)] user:String,
    #[serde(default)] password:String, #[serde(default)] code:String,
    #[serde(default)] routes:Vec<String>,
}
impl Drop for Command {fn drop(&mut self){self.password.zeroize();self.code.zeroize();}}
struct Login { session:Session,info:GatewayInfo,user:String,password:Zeroizing<String>,challenge:Option<AuthReply> }
async fn captcha(login:&Login)->Result<()> {
    let url=login.info.captcha.clone().context("网关未提供图片验证码地址")?;
    let bytes=login.session.request_bytes(url,None,false).await?;
    ensure!(bytes.len()<=512*1024,"验证码图片过大");
    event(json!({"event":"captcha","image":base64::engine::general_purpose::STANDARD.encode(bytes)})); Ok(())
}
async fn reply(login:&mut Login,r:AuthReply,args:&ConnectArgs)->Result<bool> {
    match r.result.as_str() {
        "Success"=> {
            login.password.zeroize();
            login.challenge=None;
            event(json!({"event":"authenticated"}));
            let result=connection::connected(&login.session,args).await;
            result?; event(json!({"event":"disconnected"})); Ok(true)
        },
        "Challenge" if ["SMS","SMS-GW","SMS-IMC"].contains(&r.kind.as_str())=> {
            event(json!({"event":"sms","message":"短信已由网关发送，请填写验证码","interval":r.interval}));
            login.challenge=Some(r);Ok(false)
        },
        _=>bail!("认证未完成：{}。请核对输入；不会自动重试。",protocol::authentication_summary(&r.message))
    }
}
async fn run(mut rx:tokio::sync::mpsc::Receiver<Command>)->Result<()> {
    let mut login:Option<Login>=None;
    let mut args=ConnectArgs{route:vec![],gateway_routes:true,mtu:1400,reconnect_attempts:5};
    event(json!({"event":"ready"}));
    while let Some(mut c)=rx.recv().await {
        let result:Result<bool>=async {
            match c.op.as_str() {
                "start" if c.mode=="portal"=>{
                    let password=Zeroizing::new(std::mem::take(&mut c.password));
                    desktop_portal::connected(&c.gateway,&c.user,password,&c.domain).await?;
                    return Ok(true);
                },
                "start"=> {
                    ensure!(login.is_none(),"连接正在进行");
                    ensure!(!c.user.is_empty()&&!c.password.is_empty(),"请填写账号密码");
                    args.route=c.routes.iter().map(|s|s.parse()).collect::<Result<_,_>>()?;
                    let session=desktop_policy::session(&c.gateway,Duration::from_secs(20))?
                        .with_keepalive(Some(Duration::from_secs(30)));
                    let info=session.discover(if c.domain.is_empty(){None}else{Some(&c.domain)}).await?;
                    let l=Login{session,info,user:std::mem::take(&mut c.user),password:Zeroizing::new(std::mem::take(&mut c.password)),challenge:None};
                    login=Some(l);
                    let l=login.as_ref().unwrap();
                    if l.info.captcha.is_some(){captcha(l).await?;} else {
                        let r=l.session.authenticate_step(&l.info,&l.user,&l.password,None,None).await?;
                        return reply(login.as_mut().unwrap(),r,&args).await;
                    }
                },
                "refresh"=>{captcha(login.as_ref().context("会话尚未建立")?).await?;},
                "captcha"|"sms"=> {
                    ensure!(!c.code.trim().is_empty(),"请输入验证码");
                    let l=login.as_mut().context("会话尚未建立")?;
                    let sms=if c.op=="sms" {let r=l.challenge.as_ref().context("尚未进入短信认证")?;Some((r.kind.as_str(),c.code.as_str(),r.dynamic.as_str()))}else{None};
                    let r=l.session.authenticate_step(&l.info,&l.user,&l.password,if c.op=="captcha"{Some(&c.code)}else{None},sms).await?;
                    return reply(l,r,&args).await;
                },
                _=>bail!("未知命令"),
            } Ok(false)
        }.await;
        match result {Ok(true)=>break,Ok(false)=>{},Err(e)=>{event(json!({"event":"error","message":format!("{e:#}")}));break;}}
    }
    if let Some(l)=login {l.session.logout(&l.info).await;}
    Ok(())
}
fn main()->Result<()> {
    let a:Vec<_>=std::env::args().collect();
    if a.len()==3&&(a[1]=="--domains"||a[1]=="--portal-domains") {
        let result=tokio::runtime::Runtime::new()?.block_on(async {
            if a[1]=="--portal-domains" {
                let info=desktop_portal::Portal::discover(&a[2]).await?.info;
                let options=portal_reply::domain_options(&info);
                let default=options.iter().find(|o|o.name=="客户端").map(|o|o.id.as_str()).unwrap_or("");
                Ok::<_,anyhow::Error>(json!({"domains":info.domains(),"domainOptions":options,"defaultDomain":default}))
            }
            else{Ok(json!({"domains":desktop_queries::domains(&a[2]).await?}))}
        })?;
        println!("{result}");return Ok(());
    }
    ensure!(a.len()==4,"Expected socket path, uid and UI pid");
    let uid:u32=a[2].parse()?;ensure!(uid>0,"Invalid desktop user");
    desktop_broker::bootstrap(uid)?;
    tokio::runtime::Runtime::new()?.block_on(desktop_main())
}
async fn desktop_main()->Result<()> {
    let a:Vec<_>=std::env::args().collect();ensure!(a.len()==4,"Expected socket path, uid and UI pid");
    let expected_pid:libc::pid_t=a[3].parse()?;ensure!(expected_pid>0,"Invalid UI pid");
    let uid:u32=a[2].parse()?;ensure!(uid>0,"Invalid desktop user");
    let path=std::path::Path::new(&a[1]);let parent=path.parent().context("Missing socket directory")?;
    let meta=std::fs::symlink_metadata(parent)?;
    ensure!(meta.is_dir()&&meta.uid()==uid&&meta.mode()&0o077==0,"IPC directory must belong to user and be private");
    ensure!(path.file_name().is_some_and(|n|n=="control.sock"),"Invalid socket filename");
    let listener=UnixListener::bind(path)?;
    std::fs::set_permissions(path,std::fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    let deadline=std::time::Instant::now()+Duration::from_secs(90);
    let stream=loop {match listener.accept(){Ok((s,_))=>break s,Err(e)if e.kind()==std::io::ErrorKind::WouldBlock=>{ensure!(std::time::Instant::now()<deadline,"Desktop connection timeout");tokio::time::sleep(Duration::from_millis(100)).await;},Err(e)=>return Err(e.into())}};
    // On macOS accept() inherits O_NONBLOCK from the listening socket.
    // The command reader runs on its own blocking thread: an idle client must
    // wait for the next command rather than interpreting EAGAIN as disconnect.
    stream.set_nonblocking(false)?;
    use std::os::fd::AsRawFd;
    let(mut peer,mut group)=(0,0);
    ensure!(unsafe{libc::getpeereid(stream.as_raw_fd(),&mut peer,&mut group)}==0&&peer==uid,"Unauthorized IPC peer");
    let mut peer_pid:libc::pid_t=0;let mut pid_len=std::mem::size_of_val(&peer_pid) as libc::socklen_t;
    ensure!(unsafe{libc::getsockopt(stream.as_raw_fd(),0,libc::LOCAL_PEERPID,(&mut peer_pid as *mut libc::pid_t).cast(),&mut pid_len)}==0&&peer_pid==expected_pid,"Unexpected UI process");
    std::fs::remove_file(path)?;
    OUTPUT.set(Mutex::new(stream.try_clone()?)).ok();
    let(tx,rx)=tokio::sync::oneshot::channel();STOP.set(Mutex::new(Some(tx))).ok();STOP_RX.set(Mutex::new(Some(rx))).ok();
    let(tx,rx)=tokio::sync::mpsc::channel(8);
    std::thread::spawn(move||{
        let mut reader=BufReader::with_capacity(1,stream);
        loop {
            let mut bytes=Zeroizing::new(Vec::new());
            use std::io::Read;
            let n=reader.by_ref().take(65537).read_until(b'\n',&mut bytes);
            if n.is_err()||bytes.is_empty()||bytes.len()>65536 {break;}
            let c:Command=match serde_json::from_slice(&bytes){Ok(c)=>c,Err(_)=>break};
            bytes.zeroize();
            if c.op=="stop"{break;}
            if tx.blocking_send(c).is_err(){break;}
        }
        if let Some(tx)=STOP.get().unwrap().lock().unwrap().take(){let _=tx.send(());}
    });
    run(rx).await
}
