#!/bin/zsh
# Makes the two test torrents used by Tests/stream (audiobook, index at the end)
# and Tests/subs (video with subtitle files and an embedded track). Needs ffmpeg.
# usage: Tests/stream/make_fixtures.sh <output dir>   -> <dir>/syn and <dir>/syn2
set -e
OUT="${1:?output dir}"
mkdir -p "$OUT/syn/seed" "$OUT/syn2/seed/Show"
cd "$OUT/syn"
ffmpeg -loglevel error -y -f lavfi -i "color=c=0x8a1c3a:s=600x600" -frames:v 1 cover.png
cat > meta.txt <<'META'
;FFMETADATA1
title=The Test Book
artist=A. Author
album=The Test Book
[CHAPTER]
TIMEBASE=1/1000
START=0
END=600000
title=Chapter One
[CHAPTER]
TIMEBASE=1/1000
START=600000
END=1200000
title=Chapter Two
[CHAPTER]
TIMEBASE=1/1000
START=1200000
END=1800000
title=Chapter Three
META
ffmpeg -loglevel error -y -f lavfi -i "anoisesrc=d=1800:c=pink:r=44100:a=0.05" -i cover.png -i meta.txt \
  -map 0:a -map 1:v -map_metadata 2 -map_chapters 2 -c:a aac -b:a 96k -c:v mjpeg -disposition:v:0 attached_pic -f ipod seed/test.m4b
cd "$OUT/syn2"
printf '1\n00:00:01,000 --> 00:00:04,000\nHello from the English file\n\n2\n00:00:05,000 --> 00:00:08,000\n<i>Second English line</i>\n' > seed/Show/video.en.srt
printf '1\n00:00:01,000 --> 00:00:04,000\nHola desde el archivo español\n' > seed/Show/video.es.srt
printf '1\n00:00:01,000 --> 00:00:04,000\nEmbedded track text\n' > emb.srt
ffmpeg -loglevel error -y -f lavfi -i "testsrc=duration=40:size=640x360:rate=24" -f lavfi -i "sine=frequency=300:duration=40" -i emb.srt \
  -map 0:v -map 1:a -map 2:s -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -c:s mov_text \
  -metadata:s:s:0 language=fra seed/Show/video.mp4
python3 - "$OUT" <<'PY'
import hashlib, os, sys
def enc(v):
    if isinstance(v,int): return b'i%de'%v
    if isinstance(v,str): v=v.encode()
    if isinstance(v,bytes): return b'%d:'%len(v)+v
    if isinstance(v,list): return b'l'+b''.join(enc(x) for x in v)+b'e'
    return b'd'+b''.join(enc(k)+enc(v[k]) for k in sorted(v))+b'e'
out=sys.argv[1]
d=open(out+'/syn/seed/test.m4b','rb').read(); pl=262144
pieces=b''.join(hashlib.sha1(d[i:i+pl]).digest() for i in range(0,len(d),pl))
open(out+'/syn/test.torrent','wb').write(enc({'info':{'name':'test.m4b','length':len(d),'piece length':pl,'pieces':pieces},'creation date':1792860000}))
names=sorted(os.listdir(out+'/syn2/seed/Show')); blob=b''; files=[]
for n in names:
    x=open(out+'/syn2/seed/Show/'+n,'rb').read(); blob+=x; files.append({'length':len(x),'path':[n]})
pl=16384
pieces=b''.join(hashlib.sha1(blob[i:i+pl]).digest() for i in range(0,len(blob),pl))
open(out+'/syn2/test.torrent','wb').write(enc({'info':{'name':'Show','files':files,'piece length':pl,'pieces':pieces},'creation date':1792860000}))
PY
echo "fixtures in $OUT/syn and $OUT/syn2"
