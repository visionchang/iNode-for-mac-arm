#!/usr/bin/env python3
"""Independent Portal/VPN IPC processes; local mock, no routes or real credentials."""
import hashlib,json,os,pathlib,shutil,socket,subprocess,sys,tempfile,threading,time
core=pathlib.Path(sys.argv[1]).resolve()
key=b'hello';counts=threading.Condition();heartbeats=0;errors=[]
server=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);server.bind(('127.0.0.1',0));server.settimeout(10)
endpoint='127.0.0.1:'+str(server.getsockname()[1])
def respond(kind,serial,attrs):
 b=bytearray(32);b[0]=2;b[1]=kind;b[4:6]=serial;b[8:12]=socket.inet_aton('127.0.0.1');b[15]=len(attrs)
 for k,v in attrs:b+=bytes([k,len(v)+2])+v
 b[16:32]=hashlib.md5(b+key).digest();return b
def serve():
 global heartbeats
 try:
  while True:
   data,peer=server.recvfrom(4096);check=bytearray(data);check[16:32]=bytes(16)
   assert hashlib.md5(check+key).digest()==data[16:32]
   kind=data[1];serial=data[4:6]
   if kind==110:reply=respond(111,serial,[(60,b'portal,')])
   elif kind==100:reply=respond(101,serial,[(100,b'12345678'),(114,b'session-user'),(109,(30).to_bytes(8,'big')),(119,(300).to_bytes(8,'big'))])
   elif kind==104:
    reply=respond(105,serial,[])
    with counts:heartbeats+=1;counts.notify_all()
   elif kind==102:reply=respond(103,serial,[])
   else:raise AssertionError(kind)
   server.sendto(reply,peer)
   if kind==102:return
 except Exception as error:errors.append(error)
thread=threading.Thread(target=serve);thread.start()
class Core:
 def __init__(self):
  self.folder=pathlib.Path(tempfile.mkdtemp(prefix='ia-concurrent-',dir='/private/tmp'));self.folder.chmod(0o700);self.path=self.folder/'control.sock'
  self.p=subprocess.Popen([str(core),str(self.path),str(os.getuid()),str(os.getpid())],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
  self.sock=socket.socket(socket.AF_UNIX);self.sock.settimeout(5)
  until=time.monotonic()+5
  while not self.path.exists():
   assert self.p.poll() is None and time.monotonic()<until;time.sleep(.01)
  self.sock.connect(str(self.path));self.reader=self.sock.makefile('rb');assert self.read()['event']=='ready'
 def read(self):return json.loads(self.reader.readline())
 def send(self,command):self.sock.sendall((json.dumps(command)+'\n').encode())
 def exited(self):assert self.p.wait(timeout=5)==0,self.p.stderr.read().decode()
 def close(self):
  self.reader.close();self.sock.close()
  if self.p.poll() is None:self.p.terminate();self.p.wait(timeout=5)
  self.p.stderr.close();shutil.rmtree(self.folder)
def more_heartbeats():
 with counts:
  expected=heartbeats+2
  assert counts.wait_for(lambda:heartbeats>=expected,timeout=3),errors
sessions=[]
try:
 portal=Core();sessions.append(portal)
 portal.send({'op':'start','mode':'portal','gateway':endpoint,'domain':'portal','user':'dummy','password':'dummy-password'})
 assert portal.read()['event']=='authenticated';assert portal.read()['event']=='connected'
 vpn=Core();sessions.append(vpn)
 assert vpn.path!=portal.path and vpn.p.pid!=portal.p.pid
 more_heartbeats();assert vpn.p.poll() is None and portal.p.poll() is None
 vpn.send({'op':'stop'});vpn.exited();more_heartbeats();assert portal.p.poll() is None
 print('PASS: simultaneous IPC processes; stopping VPN leaves Portal heartbeats running')
 vpn_failure=Core();sessions.append(vpn_failure)
 vpn_failure.send({'op':'start','mode':'vpn','gateway':'://','user':'dummy','password':'dummy-password'})
 assert vpn_failure.read()['event']=='error';vpn_failure.exited();more_heartbeats();assert portal.p.poll() is None
 print('PASS: VPN startup failure cannot stop or redirect Portal IPC')
 portal.send({'op':'stop'});assert portal.read()['event']=='disconnected';portal.exited()
 thread.join(timeout=3);assert not thread.is_alive() and not errors,errors
 print('PASS: Portal explicitly logs out after the other cores have exited')
finally:
 for session in reversed(sessions):session.close()
 server.close();thread.join(timeout=10)
