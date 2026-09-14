#!/usr/bin/env python3
"""Remnawave setup v2 SAFE. Single file. stdlib only. No DELETE/PATCH, no node reassignment."""
import argparse,getpass,hashlib,json,os,secrets,socket,subprocess,sys
from datetime import datetime,timezone
from pathlib import Path
from urllib.request import Request,urlopen
from urllib.error import HTTPError,URLError

VER="2.4.0-safe-single"; PLAN="/root/remnawave-auto-plan.json"; STATE="/root/remnawave-auto-state.json"; OUT="/root/remnawave-profile.json"; BACK="/root/remnawave-auto-backups"
def sh(*x): return subprocess.run(x,text=True,capture_output=True)
def save(p,x):
 p=Path(p);p.parent.mkdir(parents=True,exist_ok=True);t=Path(str(p)+".tmp");t.write_text(json.dumps(x,ensure_ascii=False,indent=2)+"\n");os.chmod(t,0o600);os.replace(t,p);os.chmod(p,0o600)
def unwrap(x): return x.get("response") if isinstance(x,dict) and "response" in x else x
def h(x): return hashlib.sha256(json.dumps(x,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest()
class API:
 def __init__(s,url,tok,key=None):
  if not url.startswith("https://"): raise RuntimeError("Panel URL must be HTTPS")
  s.u=url.rstrip("/")+("" if url.rstrip("/").endswith("/api") else "/api");s.t=tok;s.k=key
 def q(s,m,p,b=None):
  if m not in ("GET","POST"): raise RuntimeError("SAFE mode allows only GET/POST")
  hd={"Authorization":s.t if s.t.startswith("Bearer ") else "Bearer "+s.t,"Accept":"application/json"};d=None
  if s.k: hd["X-Api-Key"]=s.k
  if b is not None: d=json.dumps(b).encode();hd["Content-Type"]="application/json"
  try:
   with urlopen(Request(s.u+p,data=d,headers=hd,method=m),timeout=30) as r:
    z=r.read().decode();return unwrap(json.loads(z) if z else None)
  except HTTPError as e: raise RuntimeError(f"API {e.code} {m} {p}: {e.read().decode(errors='replace')[:800]}")
  except URLError as e: raise RuntimeError(f"API connection: {e}")
 def get(s,p): return s.q("GET",p)
 def post(s,p,b): return s.q("POST",p,b)
def arr(x,k=None): return (x.get(k,[]) if k and isinstance(x,dict) else x) if isinstance(x,(dict,list)) else []
def inv(a): return {"profiles":arr(a.get("/config-profiles"),"configProfiles"),"hosts":arr(a.get("/hosts")),"squads":arr(a.get("/internal-squads"),"internalSquads"),"nodes":arr(a.get("/nodes"))}
def uid(x):
 if not isinstance(x,dict) or not x.get("uuid"): raise RuntimeError(f"API response has no uuid: {x}")
 return str(x["uuid"])
def token(a): return a.panel_token or os.getenv("REMNAWAVE_TOKEN") or getpass.getpass("Remnawave API token: ")
def api(a):
 if not a.panel_url: raise RuntimeError("Need --panel-url or REMNAWAVE_BASE_URL")
 return API(a.panel_url,token(a),a.panel_api_key or os.getenv("REMNAWAVE_API_KEY"))
def docker(a): return a.container in sh("docker","ps","--format","{{.Names}}").stdout.splitlines()
def keys(a):
 p=sh("docker","exec",a.container,"rw-core","x25519");raw=p.stdout+p.stderr;pr=pu=""
 for l in raw.splitlines():
  if ":" in l:
   k,v=l.split(":",1);k=k.lower();v=v.strip()
   if "private" in k: pr=v
   elif "public" in k or "password" in k: pu=v
 if not pr or not pu: raise RuntimeError("Could not parse Reality keys")
 return pr,pu
def pre(a):
 if not docker(a): raise RuntimeError(f"Container {a.container} not running")
 for p in (a.hysteria_cert,a.hysteria_key):
  if sh("docker","exec",a.container,"test","-f",p).returncode: raise RuntimeError(f"Missing in container: {p}")
 ips=sorted({x[4][0] for x in socket.getaddrinfo(a.domain,None,socket.AF_INET)});print("[OK] DNS",a.domain,ips)
 with socket.create_connection((a.reality_target,443),5): pass
 print("[OK] local preflight")
def cfg(a,pr,sid): return {"log":{"loglevel":"warning"},"dns":{"servers":["1.1.1.1","8.8.8.8"],"queryStrategy":"UseIPv4"},"inbounds":[{"tag":a.hysteria_tag,"port":443,"listen":"0.0.0.0","protocol":"hysteria","settings":{"users":[],"clients":[],"version":2},"streamSettings":{"network":"hysteria","security":"tls","tlsSettings":{"alpn":["h3"],"certificates":[{"keyFile":a.hysteria_key,"certificateFile":a.hysteria_cert}]},"hysteriaSettings":{"version":2}}},{"tag":a.reality_tag,"port":443,"listen":"0.0.0.0","protocol":"vless","settings":{"clients":[],"decryption":"none"},"sniffing":{"enabled":True,"routeOnly":True,"destOverride":["http","tls","quic"]},"streamSettings":{"network":"tcp","sockopt":{"mark":255,"tcpNoDelay":True,"tcpFastOpen":True},"security":"reality","tcpSettings":{"header":{"type":"none"},"acceptProxyProtocol":False},"realitySettings":{"dest":a.reality_target+":443","show":False,"xver":0,"spiderX":"","shortIds":[sid],"privateKey":pr,"serverNames":[a.reality_target]}}}],"outbounds":[{"tag":"DIRECT","protocol":"freedom","settings":{"domainStrategy":"UseIPv4"}},{"tag":"BLOCK","protocol":"blackhole"}],"routing":{"rules":[{"type":"field","protocol":["bittorrent"],"outboundTag":"BLOCK"}],"domainStrategy":"IPIfNonMatch"}}
def sig(a): return {k:getattr(a,k) for k in ("domain","profile_name","squad_name","hysteria_tag","reality_tag","hysteria_host_name","reality_host_name","hysteria_cert","hysteria_key","reality_target")} | {"panel_url":(a.panel_url or "").rstrip("/")}
def clash(i,a):
 x=[]
 for p in i["profiles"]:
  if p.get("name")==a.profile_name:x.append("Profile "+a.profile_name)
 for s in i["squads"]:
  if s.get("name")==a.squad_name:x.append("Squad "+a.squad_name)
 for z in i["hosts"]:
  if z.get("remark") in (a.hysteria_host_name,a.reality_host_name):x.append("Host "+str(z.get("remark")))
 return x
def names(a):
 for v,p in ((a.profile_name,"TEST-"),(a.squad_name,"TEST-"),(a.hysteria_host_name,"TEST "),(a.reality_host_name,"TEST ")):
  if not v.startswith(p) and not a.production_names: raise RuntimeError("Test names required; use --production-names only after testing")
def plan(a):
 names(a);pre(a);q=api(a);i=inv(q);c=clash(i,a)
 print("[SAFE] PLAN only. Panel fingerprint",h(i))
 if c: raise RuntimeError("Existing objects collision: "+", ".join(c))
 pr,pu=keys(a);sid=secrets.token_hex(8);co=cfg(a,pr,sid);save(a.output,co);save(a.plan,{"version":VER,"signature":sig(a),"fingerprint":h(i),"config":co,"publicKey":pu,"shortId":sid})
 print("[SAFE] Panel unchanged");print("[OK] PublicKey",pu);print("[OK] ShortID",sid);print("[OK] Plan",a.plan);return 0
def backup(i,a):
 d=Path(a.backup_dir)/datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ");d.mkdir(parents=True);os.chmod(d,0o700)
 for k,v in i.items():save(d/(k+".json"),v)
 return d
def execute(a):
 names(a)
 if a.confirm!="CREATE-ONLY": raise RuntimeError("Need --confirm CREATE-ONLY")
 if not Path(a.plan).exists(): raise RuntimeError("Run plan first")
 p=json.loads(Path(a.plan).read_text());
 if p.get("version")!=VER or p.get("signature")!=sig(a): raise RuntimeError("Plan version/arguments mismatch; run plan again")
 pre(a);q=api(a);i=inv(q)
 if h(i)!=p.get("fingerprint"): raise RuntimeError("Panel changed since plan; run plan again")
 if clash(i,a): raise RuntimeError("Collision appeared after plan")
 print("[SAFE] Snapshot",backup(i,a));st={"version":VER,"created":{},"status":"started"};save(a.state,st)
 try:
  pro=q.post("/config-profiles",{"name":a.profile_name,"config":p["config"]});pu=uid(pro);st["created"]["profileUuid"]=pu;save(a.state,st)
  rows=arr(q.get(f"/config-profiles/{pu}/inbounds"));m={x.get("tag"):x for x in rows};hi,ri=uid(m[a.hysteria_tag]),uid(m[a.reality_tag]);st["created"].update({"hysteriaInboundUuid":hi,"realityInboundUuid":ri});save(a.state,st)
  s=q.post("/internal-squads",{"name":a.squad_name,"inbounds":[hi,ri]});st["created"]["squadUuid"]=uid(s);save(a.state,st)
  rh=q.post("/hosts",{"inbound":{"configProfileUuid":pu,"configProfileInboundUuid":ri},"remark":a.reality_host_name,"address":a.domain,"port":443,"sni":a.reality_target,"fingerprint":"chrome","nodes":[],"isDisabled":False,"isHidden":False});st["created"]["realityHostUuid"]=uid(rh);save(a.state,st)
  hh=q.post("/hosts",{"inbound":{"configProfileUuid":pu,"configProfileInboundUuid":hi},"remark":a.hysteria_host_name,"address":a.domain,"port":443,"sni":a.domain,"nodes":[],"isDisabled":False,"isHidden":False});st["created"]["hysteriaHostUuid"]=uid(hh);st["status"]="created";save(a.state,st)
 except Exception:
  print("[STOP] Partial state",a.state,"; NO auto-delete was performed");raise
 print("[OK] Created new test objects only. Existing panel objects and nodes were NOT changed.");return 0
def doctor(a):
 if not docker(a):return 1
 p=sh("docker","exec",a.container,"cli","--dump-config-raw");
 if p.returncode:print(p.stderr);return 1
 d=json.loads(p.stdout);m={x.get("tag"):x for x in d.get("inbounds",[])};r=m.get(a.reality_tag);ok=True
 if a.hysteria_tag not in m:print("[ERR] Hysteria missing");ok=False
 if not r:print("[ERR] Reality missing");return 1
 ss=r.get("streamSettings",{});rs=ss.get("realitySettings",{});sett=r.get("settings",{})
 for name,v in (("network tcp",ss.get("network")=="tcp"),("security reality",ss.get("security")=="reality"),("flow vision",sett.get("flow")=="xtls-rprx-vision"),("dest",rs.get("dest")==a.reality_target+":443"),("users",bool(sett.get("clients")))): print("[OK]" if v else "[ERR]",name);ok &= v
 return 0 if ok else 1
def selftest(a):
 class X:pass
 x=X();x.hysteria_tag="H";x.reality_tag="R";x.hysteria_key="k";x.hysteria_cert="c";x.reality_target="ads.x5.ru";z=cfg(x,"P","0123456789abcdef");r=z["inbounds"][1]
 assert r["streamSettings"]["network"]=="tcp" and r["streamSettings"]["sockopt"]["mark"]==255 and r["streamSettings"]["realitySettings"]["dest"]=="ads.x5.ru:443"
 src=Path(__file__).read_text();forbidden=['q('+chr(34)+'DELETE'+chr(34),'q('+chr(34)+'PATCH'+chr(34)];assert not any(x in src for x in forbidden)
 print("[OK] self-test; sha256",hashlib.sha256(src.encode()).hexdigest());return 0
def parser():
 p=argparse.ArgumentParser();p.add_argument("command",choices=["plan","execute","doctor","self-test"]);p.add_argument("--domain");p.add_argument("--panel-url",default=os.getenv("REMNAWAVE_BASE_URL"));p.add_argument("--panel-token");p.add_argument("--panel-api-key");p.add_argument("--container",default="remnanode");p.add_argument("--profile-name",default="TEST-AUTO-H2-REALITY");p.add_argument("--squad-name",default="TEST-AUTO-H2-REALITY");p.add_argument("--hysteria-tag",default="HYSTERIA-BBR-TEST");p.add_argument("--reality-tag",default="REALITY-TCP-TEST");p.add_argument("--hysteria-host-name",default="TEST AUTO Hysteria");p.add_argument("--reality-host-name",default="TEST AUTO Reality");p.add_argument("--hysteria-cert",default="/opt/hysteria/certs/fullchain.pem");p.add_argument("--hysteria-key",default="/opt/hysteria/certs/privkey.pem");p.add_argument("--reality-target",default="ads.x5.ru");p.add_argument("--production-names",action="store_true");p.add_argument("--confirm");p.add_argument("--output",default=OUT);p.add_argument("--plan",default=PLAN);p.add_argument("--state",default=STATE);p.add_argument("--backup-dir",default=BACK);return p
def main():
 a=parser().parse_args()
 if a.command in ("plan","execute") and not a.domain:raise SystemExit("Need --domain")
 try:return {"plan":plan,"execute":execute,"doctor":doctor,"self-test":selftest}[a.command](a)
 except Exception as e:print("[ERR]",e,file=sys.stderr);return 1
if __name__=="__main__":raise SystemExit(main())
