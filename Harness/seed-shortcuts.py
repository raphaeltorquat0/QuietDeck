#!/usr/bin/env python3
# shortcuts.vdf inicial, com um campo que o QuietDeck não conhece: ele tem que sobreviver.
import struct, sys
def s(k, v): return b"\x01" + k.encode() + b"\0" + v.encode() + b"\0"
def i(k, v): return b"\x02" + k.encode() + b"\0" + struct.pack("<i", v)
entry = i("appid", -1000) + s("AppName", "Existing Game") + s("Exe", '"/usr/bin/existing"') + s("FutureField", "keep me") + b"\x00tags\0\x08"
data = b"\x00shortcuts\0" + b"\x000\0" + entry + b"\x08" + b"\x08" + b"\x08"
open(sys.argv[1], "wb").write(data)
