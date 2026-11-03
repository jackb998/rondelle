import sys,struct
# mkmp3.py BASE.mp3 OUT.mp3 KIND N: N tags of KIND (id3 at the start, ape / 3di / v1 at the end) around the audio.
base,out,kind,n=sys.argv[1],sys.argv[2],sys.argv[3],int(sys.argv[4])
audio=open(base,'rb').read()
def ss(x): return bytes([(x>>21)&127,(x>>14)&127,(x>>7)&127,x&127])
def frame(i): t=b'\x03'+('Segreto%d'%i).encode(); return b'TIT2'+struct.pack('>I',len(t))+b'\x00\x00'+t
def id3(i): body=frame(i); return b'ID3\x04\x00\x00'+ss(len(body))+body
def id3footer(i): body=frame(i); return b'ID3\x04\x00\x10'+ss(len(body))+body+b'3DI\x04\x00\x10'+ss(len(body))
def ape(i):
    v=('Segreto%d'%i).encode(); item=struct.pack('<II',len(v),0)+b'Title\x00'+v
    size=len(item)+32
    return item+b'APETAGEX'+struct.pack('<IIII',2000,size,1,0)+b'\x00'*8
def v1(i): return (b'TAG'+('Segreto%d'%i).encode().ljust(30,b'\x00')).ljust(128,b'\x00')
if kind=='id3': data=b''.join(id3(i) for i in range(n))+audio
else:
    f={'ape':ape,'3di':id3footer,'v1':v1}[kind]
    data=audio+b''.join(f(i) for i in range(n))
open(out,'wb').write(data)
