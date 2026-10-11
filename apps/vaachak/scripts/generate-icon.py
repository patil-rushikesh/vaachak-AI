"""Generate the simple geometric Vaachak mark without third-party image tools."""
import struct,zlib
from pathlib import Path

def png(size,path):
 rows=[]
 for y in range(size):
  row=bytearray([0])
  for x in range(size):
   u,v=x/size,y/size
   color=(35,122,80,255)
   if ((u-.50)/.29)**2+((v-.46)/.25)**2<=1 or (.29<u<.47 and .58<v<.74 and v<.97-u):color=(247,249,245,255)
   if any((u-cx)**2+(v-.46)**2<.0012 for cx in (.39,.5,.61)):color=(35,122,80,255)
   row.extend(color)
  rows.append(row)
 def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
 Path(path).write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',size,size,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(b''.join(rows)))+chunk(b'IEND',b''))
png(1024,'assets/icon.png');png(64,'assets/favicon.png')
