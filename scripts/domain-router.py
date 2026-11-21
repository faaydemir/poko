#!/usr/bin/python3
"""System-owned loopback front listener and narrowly scoped hosts-file synchronizer."""
import os, sys, json, re, stat, socket, select, threading, time, fcntl
registry, report, owner = sys.argv[1], sys.argv[2], int(sys.argv[3])
begin, end = '# BEGIN PORT APP DOMAINS', '# END PORT APP DOMAINS'
limit=threading.BoundedSemaphore(128)
def names():
    fd=os.open(registry,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd) as f:
        info=os.fstat(f.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=owner or info.st_size>1048576: raise ValueError('Invalid registry ownership or size')
        data=json.load(f)
    result=set()
    for app in data.get('apps',[]):
        if not app.get('accepted'): continue
        name=app.get('hostname') or app.get('name','')
        if not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?',name) or name in ('localhost','broadcasthost','ip6-localhost'): raise ValueError('Invalid app domain')
        result.add(name)
    if len(result)>500: raise ValueError('Too many domains')
    return sorted(result)
def sync_hosts(domains):
    fd=os.open('/etc/hosts',os.O_RDWR|os.O_NOFOLLOW)
    with os.fdopen(fd,'r+') as f:
        fcntl.flock(f,fcntl.LOCK_EX)
        text=f.read()
        if text.count(begin)!=text.count(end) or text.count(begin)>1: raise ValueError('Malformed Port hosts block; repair before continuing')
        clean=re.sub(r'(?m)^'+re.escape(begin)+r'\n.*?^'+re.escape(end)+r'\n?', '', text, flags=re.S)
        for line in clean.splitlines():
            fields=line.split('#',1)[0].split()
            if len(fields)>1 and fields[0]!='127.0.0.1' and set(fields[1:])&set(domains): raise ValueError('App domain conflicts with an existing hosts entry')
        block=begin+'\n'+''.join('127.0.0.1 '+name+'\n' for name in domains)+end+'\n'
        updated=clean.rstrip('\n')+'\n\n'+block
        if updated!=text: f.seek(0);f.write(updated);f.truncate();f.flush();os.fsync(f.fileno())
def publish(data):
    # Never follow a user-created symlink as root.
    fd=os.open(report,os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o644)
    with os.fdopen(fd,'w') as f: json.dump(dict(data,updatedAt=time.time()),f)
def sync_loop():
    while True:
        try:
            try: domains=names()
            except FileNotFoundError: domains=[]
            sync_hosts(domains);publish({'ready':True,'domains':domains})
        except Exception as e:
            try: publish({'ready':False,'error':str(e)})
            except Exception: pass
        time.sleep(1)
def relay(client):
    upstream=None
    try:
        client.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,1)
        upstream=socket.create_connection(('127.0.0.1',47832),timeout=3)
        upstream.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,1)
        client.settimeout(15);upstream.settimeout(15)
        while True:
            readable,_,_=select.select([client,upstream],[],[],300)
            if not readable: break
            for source in readable:
                data=source.recv(32768)
                if not data: return
                (upstream if source is client else client).sendall(data)
    except OSError: pass
    finally:
        client.close()
        if upstream: upstream.close()
        limit.release()
server=socket.socket();server.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
server.bind(('127.0.0.1',80));server.listen(64)
threading.Thread(target=sync_loop,daemon=True).start()
while True:
    client,_=server.accept()
    if limit.acquire(False): threading.Thread(target=relay,args=(client,),daemon=True).start()
    else: client.close()
