import json, subprocess, collections

max_blocks = 120
raw = subprocess.check_output([
    'kubectl','get','blockaffinities.crd.projectcalico.org','-o','json'
], text=True)
obj = json.loads(raw)
counts = collections.Counter()
for item in obj.get('items', []):
    spec = item.get('spec', {})
    if spec.get('deleted') is True:
        continue
    if spec.get('state') != 'confirmed':
        continue
    node = spec.get('node')
    if node:
        counts[node] += 1

nodes_raw = subprocess.check_output(['kubectl','get','nodes','-o','json'], text=True)
nodes = [i['metadata']['name'] for i in json.loads(nodes_raw).get('items', [])]

print(f"maxBlocksPerHost={max_blocks}")
for n in sorted(nodes):
    used = counts.get(n, 0)
    remain = max_blocks - used
    print(f"{n}\tused={used}\tremaining={remain}")