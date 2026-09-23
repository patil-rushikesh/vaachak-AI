"""Loopback-only path/CORS gateway to real local PostgREST; no mock RPCs."""
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
import http.client
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_OPTIONS(self):
  self.send_response(204);self.send_header('Access-Control-Allow-Origin','*');self.send_header('Access-Control-Allow-Headers','authorization,apikey,content-type,accept-profile,content-profile,x-client-info');self.send_header('Access-Control-Allow-Methods','GET,POST,OPTIONS');self.end_headers()
 def do_GET(self):self.proxy()
 def do_POST(self):self.proxy()
 def proxy(self):
  if not self.path.startswith('/rest/v1/'):
   self.send_error(404);return
  n=int(self.headers.get('Content-Length','0'))
  if n>4194304:self.send_error(413);return
  conn=http.client.HTTPConnection('127.0.0.1',55433,timeout=30)
  try:
   conn.request(self.command,self.path[len('/rest/v1'):],body=self.rfile.read(n) if n else None,headers={k:v for k,v in self.headers.items() if k.lower() not in ('host','connection')})
   result=conn.getresponse();body=result.read(4194305)
   if len(body)>4194304:raise ValueError('Response exceeds limit')
   self.send_response(result.status);self.send_header('Access-Control-Allow-Origin','*');self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
  except Exception:self.send_error(502)
  finally:conn.close()
ThreadingHTTPServer(('127.0.0.1',55434),Handler).serve_forever()
