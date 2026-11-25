#!/usr/bin/env python3
"""Normal Portal IPC workflow against a local mock server; no real credentials."""
import base64,hashlib,json,os,pathlib,shutil,socket,struct,subprocess,sys,tempfile,threading,time
KEY=b'hello'
SCENARIO=sys.argv[2] if len(sys.argv)>2 else ''
REJECT=SCENARIO=='--reject'
HEARTBEAT=SCENARIO=='--heartbeat-on'
heartbeat_seen=threading.Event();heartbeat_count=0
def packet(kind,serial,attrs,error=0):
 b=bytearray(32);b[0]=2;b[1]=kind;b[4:6]=serial.to_bytes(2,'big');b[8:12]=socket.inet_aton('127.0.0.1');b[14]=error;b[15]=len(attrs)
 for k,v in attrs:b+=bytes([k,len(v)+2])+v
 b[16:32]=hashlib.md5(b+KEY).digest();return b
def parse(b):
 expected=b[16:32];check=bytearray(b);check[16:32]=bytes(16)
 assert hashlib.md5(check+KEY).digest()==expected
 attrs={};i=32
 for _ in range(b[15]):
  k,n=b[i:i+2];attrs[k]=b[i+2:i+n];i+=n
 return b[1],int.from_bytes(b[4:6],'big'),attrs
server=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);server.bind(('127.0.0.1',0));server.settimeout(10)
endpoint='127.0.0.1:'+str(server.getsockname()[1]);seen=[];errors=[];session=None
def serve():
 global session,heartbeat_count
 try:
  while True:
   b,peer=server.recvfrom(4096);kind,serial,attrs=parse(b);seen.append(kind)
   if kind==110:
    session=serial;response=packet(111,(serial+1)&65535,[(60,b'office,guest,'),(55,b'\x01')])
   elif kind==100:
    assert serial==session and attrs[101]==b'test-user@office'
    assert attrs[102]==bytes.fromhex('cc6050ab719ffd4a1872d43eca8b5c346b95cdb10cf998dad2b3265832d34baa')
    assert attrs[56]==b'\x01' and attrs[33][:2]==bytes([1,30])
    version=bytearray(base64.b64decode(attrs[33][2:30]))
    for key,n in ((b'Oly5D62FaE94W7',20),(None,16)):
     if key is None:key=version[16:20].hex().encode()
     for i in range(n):version[i]^=key[i%len(key)]^key[(n-1-i)%len(key)]
    assert version[:13]==b'CH1V7.30-0653'
    response=packet(101,(serial+2)&65535,[(115,'客户端版本无效'.encode('gbk'))],1) if REJECT else packet(101,(serial+2)&65535,[(100,b'12345678'),(114,b'server-canonical-name'),(120,(2).to_bytes(4,'big')),(109,(40 if HEARTBEAT else 0).to_bytes(8,'big')),(119,(180).to_bytes(8,'big'))])
   elif kind==104:
    assert HEARTBEAT and serial==session
    assert attrs[114]==b'server-canonical-name' and attrs[120]==(2).to_bytes(4,'big') and attrs[122]==bytes(4)
    heartbeat_count+=1
    assert attrs[125]==bytes([99 if heartbeat_count<=2 else 7])
    if heartbeat_count==1:continue
    response=packet(105,(serial+3)&65535,[(125,bytes([7])),(109,(60).to_bytes(8,'big'))])
    if heartbeat_count>=3:heartbeat_seen.set()
   elif kind==102:
    assert serial==session;response=packet(103,(serial+4)&65535,[])
   else:raise AssertionError('Unexpected Portal packet')
   server.sendto(response,peer)
   if kind==102 or (REJECT and kind==100):break
 except Exception as e:errors.append(e)
thread=threading.Thread(target=serve);thread.start()
folder=pathlib.Path(tempfile.mkdtemp(prefix='ia-portal-test-',dir='/private/tmp'));folder.chmod(0o700);path=folder/'control.sock'
core=pathlib.Path(sys.argv[1]).resolve();p=subprocess.Popen([str(core),str(path),str(os.getuid()),str(os.getpid())],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
client=socket.socket(socket.AF_UNIX);client.settimeout(10);reader=None
try:
 for _ in range(100):
  if path.exists():break
  assert p.poll() is None,p.stderr.read().decode();time.sleep(.02)
 client.connect(str(path));reader=client.makefile('rb')
 assert json.loads(reader.readline())['event']=='ready'
 client.sendall((json.dumps({'op':'start','mode':'portal','gateway':endpoint,'domain':'office','user':'test-user','password':'local-test-password'})+'\n').encode())
 if REJECT:
  error=json.loads(reader.readline());assert error['event']=='error',error
  assert '认证请求被服务器拒绝（错误码 1）' in error['message'],error
  assert '客户端版本校验失败' in error['message'],error
 else:
  assert json.loads(reader.readline())['event']=='authenticated'
  ready=json.loads(reader.readline());assert ready['event']=='connected' and ready['mode']=='portal',ready
  if HEARTBEAT:assert heartbeat_seen.wait(timeout=5),errors
  if SCENARIO=='--heartbeat-off':time.sleep(9)
  client.sendall(b'{"op":"stop"}\n')
  assert json.loads(reader.readline())['event']=='disconnected'
 assert p.wait(timeout=10)==0,p.stderr.read().decode()
 thread.join(timeout=10);assert not thread.is_alive() and not errors,errors
 assert seen.count(100)==1 and (REJECT or 102 in seen),seen
 print('PASS: '+(SCENARIO or 'normal')+'; '+('GBK rejection reason and exit' if REJECT else 'connected, explicit logout and exit'))
finally:
 if reader:reader.close()
 client.close();server.close()
 if p.poll() is None:p.terminate();p.wait(timeout=5)
 thread.join(timeout=10);shutil.rmtree(folder)
