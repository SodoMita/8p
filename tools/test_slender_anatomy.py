#!/usr/bin/env python3
"""Offline topology/provenance checks for the baked Anny body (numpy, trimesh)."""
import json
from pathlib import Path
import numpy as np
import trimesh
root=Path(__file__).resolve().parents[1]
data=json.loads((root/'assets/models/slender_anny.json').read_text())
assert data['generator'].startswith('Anny 0.6.2')
assert 'CC0' in data['license'] and data['source']=='https://github.com/naver/anny'
v=np.array(data['body_positions']);f=np.array(data['body_faces'])
body=trimesh.Trimesh(v,f,process=False)
assert body.is_watertight, 'Body/neck/skull must be one closed surface'
assert len(body.split(only_watertight=False))==1, 'No floating arms, hands or neck/head'
assert body.euler_number==2, 'Continuous genus-zero anatomical skin expected'
assert v[:,1].min()>=0 and 2.77<v[:,1].max()<2.78
# Source contains actual modeled palms/fingers, not three/four stick cylinders.
for side in [-1,1]:
 hand=v[(v[:,0]*side>.30)&(v[:,1]<.98)&(v[:,1]>.55)]
 assert len(hand)>300 and np.ptp(hand[:,0])>.045
# Closed body includes a welded neck ring at exactly the attachment height.
ring=v[np.array(data['neck_ring'])]
assert len(ring)>32 and np.max(np.abs(ring[:,1]-2.35))<1e-6
for b in data['batches']:
 p=np.array(b['vertices']);n=np.array(b['normals']);r=np.array(b['regions']);w=np.array(b['weights']);faces=np.array(b['faces'])
 assert len(p)==len(n)==len(r)==len(w)
 assert np.isfinite(p).all() and np.isfinite(n).all()
 assert np.max(np.abs(np.linalg.norm(n,axis=1)-1))<1e-4
 assert ((r>=0)&(r<=5)).all() and ((w>=0)&(w<=1)).all()
 assert faces.min()>=0 and faces.max()<len(p)
# All material splits reuse vertex labels consistently where rest coordinates
# actually coincide. Distinct offset garment surfaces intentionally differ.
seen={}
for b in data['batches']:
 for p,r,w in zip(b['vertices'],b['regions'],b['weights']):
  key=tuple(p);value=(r,round(w,6))
  if key in seen: assert seen[key]==value
  seen[key]=value
assert sum(len(x['faces']) for x in data['batches'])<35000
print(f"[anatomy-test] PASS: Anny provenance; one watertight connected body/neck/head ({len(v)} vertices / {len(f)} faces); real hand topology; shared seam labels, valid skin weights and normals; fitted garment budget")
