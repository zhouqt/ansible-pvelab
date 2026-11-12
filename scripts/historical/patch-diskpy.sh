for id in 1101 1102; do
  pct exec $id -- python3 -c "
path = '/usr/lib/python3/dist-packages/ceph_volume/util/disk.py'
with open(path) as f: code = f.read()
if 'device_slaves = []' not in code:
    code = code.replace('device_slaves = os.listdir', 'device_slaves = []\n        # device_slaves = os.listdir')
    with open(path, 'w') as f: f.write(code)
    print('$id: patched')
else:
    print('$id: already patched')
"
done
