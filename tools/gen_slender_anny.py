#!/usr/bin/env python3
"""Bake a continuous free Anny/MakeHuman-derived Slender and fitted suit.
Generation only: pip install anny==0.6.2 numpy scipy trimesh torch (CPU suffices).
No SMPL/SMPL-X assets. Runtime uses the committed JSON, not Python or Anny.
"""
from pathlib import Path
import argparse, json, os
import numpy as np
from scipy.spatial.transform import Rotation
import trimesh

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'assets/models/slender_anny.json'


def generate_source(path):
    import torch, anny
    torch.set_num_threads(2)
    # The original phenotype basis avoids the memory-heavy optional compact SVD.
    m = anny.Anny(rig='anny', topology='anny-notongue', local_changes='none',
                  facial_actions='none', phenotype_blendshapes='original').to(dtype=torch.float32, device='cpu')
    params = dict(gender=1., age=.45, weight=.18, muscle=.22, height=.9, proportions=.5)
    with torch.no_grad():
        o = m(phenotype_kwargs=params)
    np.savez(path, vertices=o['vertices'][0].numpy(), faces=m.faces.numpy(),
             poses=o['bone_poses'][0].numpy(), labels=np.array(m.bone_labels),
             weights=m.vertex_bone_weights.numpy(), indices=m.vertex_bone_indices.numpy())


def normals(v, f):
    n = np.zeros_like(v)
    crosses = np.cross(v[f[:, 1]] - v[f[:, 0]], v[f[:, 2]] - v[f[:, 0]])
    for i in range(3): np.add.at(n, f[:, i], crosses)
    return n / np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-10)


def affine_axis(v, a, b, dst_a, dst_b, width):
    src = b - a; dst = dst_b - dst_a
    src_n = src / np.linalg.norm(src); dst_n = dst / np.linalg.norm(dst)
    rot = Rotation.align_vectors(dst_n[None], src_n[None])[0].as_matrix()
    q = v - a
    axial = (q @ src_n)[:, None] * src_n
    return dst_a + ((q - axial) * width + axial * (np.linalg.norm(dst) / np.linalg.norm(src))) @ rot.T


def clip_neck(v, f, tags, joint_weights, y=2.35):
    """Clip with a shared edge-intersection cache, preserving indexed continuity."""
    verts = list(v); regions = list(tags); weights = list(joint_weights); cache = {}; faces = []
    def crossing(a, b):
        edge = tuple(sorted((a, b)))
        if edge not in cache:
            t = (y - v[a, 1]) / (v[b, 1] - v[a, 1])
            cache[edge] = len(verts)
            p = v[a] * (1 - t) + v[b] * t; p[1] = y
            verts.append(p)
            regions.append(1); weights.append(float(np.clip((y - 2.29) / .10, 0, 1)))
        return cache[edge]
    for face in f:
        poly = []
        for a, b in zip(face, np.roll(face, -1)):
            inside_a, inside_b = v[a, 1] <= y, v[b, 1] <= y
            if inside_a: poly.append(int(a))
            if inside_a != inside_b: poly.append(crossing(int(a), int(b)))
        for i in range(1, len(poly) - 1): faces.append([poly[0], poly[i], poly[i+1]])
    return np.array(verts), np.array(faces), np.array(regions), np.array(weights)


def connected_boundary(f, v):
    edges = np.sort(np.concatenate([f[:, [0,1]], f[:, [1,2]], f[:, [2,0]]]), axis=1)
    edge, counts = np.unique(edges, axis=0, return_counts=True)
    boundary = edge[counts == 1]
    links = {}
    for a,b in boundary:
        links.setdefault(int(a), []).append(int(b)); links.setdefault(int(b), []).append(int(a))
    assert all(len(x) == 2 for x in links.values()), 'Neck boundary must be a simple ring'
    ring = [next(iter(links))]; previous = -1
    while True:
        nxt = next(x for x in links[ring[-1]] if x != previous)
        if nxt == ring[0]: break
        previous = ring[-1]; ring.append(nxt)
    if len(ring) != len(links):
        print('EXTRA BOUNDARIES',len(ring),len(links),v[ring].min(0),v[ring].max(0),v[list(set(links)-set(ring))].min(0),v[list(set(links)-set(ring))].max(0))
    assert len(ring) == len(links), 'Only one neck opening is allowed'
    return ring


def compact(v, f, tags, weights):
    ids, inv = np.unique(f, return_inverse=True)
    return v[ids], inv.reshape(-1,3), tags[ids], weights[ids]


def clip_jacket(positions, faces, tags, blend):
    """Exact V and polygonal neck-hole edges, rather than centroid deletion."""
    v=list(positions); ids=list(tags); weights=list(blend); cache={}; result=[]
    def clip(poly, normal, d, plane):
        out=[]
        for a,b in zip(poly,poly[1:]+poly[:1]):
            da=np.dot(v[a],normal)+d;db=np.dot(v[b],normal)+d
            if da>=-1e-10:out.append(a)
            if (da>=0)!=(db>=0):
                key=(min(a,b),max(a,b),plane)
                if key not in cache:
                    t=da/(da-db);cache[key]=len(v)
                    v.append(np.asarray(v[a])*(1-t)+np.asarray(v[b])*t)
                    ids.append(ids[a] if t<.5 else ids[b]);weights.append(weights[a]*(1-t)+weights[b]*t)
                out.append(cache[key])
        return out
    def append(poly):
        for j in range(1,len(poly)-1):
            a,b,c=poly[0],poly[j],poly[j+1]
            if np.linalg.norm(np.cross(v[b]-v[a],v[c]-v[a]))>1e-10:result.append([a,b,c])
    for face in faces:
        poly=list(map(int,face)); center=positions[face].mean(0)
        pieces=[poly]
        if center[2]>.025 and max(positions[face,1])>1.80:
            pieces=[]
            low=clip(poly,np.array([0,-1,0]),1.80,'v-low');append(low)
            high=clip(poly,np.array([0,1,0]),-1.80,'v-high')
            for side in [-1,1]:
                part=clip(high,np.array([side,-.21,0]),.21*1.80,'v-side'+str(side)) if high else []
                if part:pieces.append(part)
        for part in pieces:
            low=clip(part,np.array([0,-1,0]),2.245,'neck-low');append(low)
            remaining=clip(part,np.array([0,1,0]),-2.245,'neck-high')
            # Subtract the convex 32-gon hole without overlapping outside pieces.
            for k in range(32):
                if not remaining:break
                a=2*np.pi*k/32;normal=np.array([-np.cos(a)/.082,-1.6,-np.sin(a)/.074])
                offset=1+1.6*2.245+.012*np.sin(a)/.074
                append(clip(remaining,-normal,-offset,'neck-out'+str(k)))
                remaining=clip(remaining,normal,offset,'neck-in'+str(k))
    return np.asarray(v),np.asarray(result),np.asarray(ids),np.asarray(weights)


def bake(source):
    raw = np.load(source)
    # Anny is Z-up with -Y forward. Godot creature is Y-up with +Z forward.
    def axes(x): return np.asarray(x)[..., [0,2,1]] * np.array([1,1,-1])
    src = axes(raw['vertices']); bones = axes(raw['poses'][:, :3, 3])
    labels = list(raw['labels']); f = raw['faces'].astype(int)
    indices, w = raw['indices'], raw['weights']
    # Segment groups use Anny's actual skinning labels, not geometric face guesses.
    bone_group = np.zeros(len(labels), int)
    for i, label in enumerate(labels):
        side = 1 if label.endswith('.L') else -1
        if label.startswith('upperarm'): bone_group[i] = 1 if side > 0 else 4
        elif label.startswith('lowerarm'): bone_group[i] = 2 if side > 0 else 5
        elif label.startswith(('wrist','finger','metacarpal')): bone_group[i] = 3 if side > 0 else 6
    group_weights = np.stack([(w * (bone_group[indices] == g)).sum(1) for g in range(1,7)], 1)
    arm_w = group_weights.sum(1)
    sy = np.array([-1.0630403,-.9800678,-.548215,-.01756065,.1278173,.39953274,.46614978,.55856752,.5988816,.63849479,.83387476])
    dy = np.array([.008,.09,.60,1.13,1.53,2.04,2.17,2.265,2.33,2.39,2.77])
    v = src.copy(); v[:,1] = np.interp(src[:,1], sy, dy)
    sx = np.interp(v[:,1], [.008,.60,1.13,1.53,2.04,2.17,2.33], [.73,.86,.92,.93,1.05,1.10,.95])
    v[:,0] *= sx
    v[:,2] *= np.interp(v[:,1],[.008,.11,1.13,1.7,2.17,2.33],[.85,.85,1.0,1.15,1.15,.92])
    # Center the real neck inside the preserved faceless head.
    neck_t = np.clip((v[:,1]-2.22)/.11,0,1)
    neck_center_z = np.interp(src[:,1], [.503,.5989,.6385], [.04,.045,.058])
    v[:,2] -= neck_t * neck_center_z
    general = v.copy()
    for side, suffix, offset in [(1,'.L',0),(-1,'.R',3)]:
        shoulder, elbow, wrist = [bones[labels.index(x+suffix)] for x in ['upperarm01','lowerarm01','wrist']]
        palm = bones[labels.index('finger3-1'+suffix)]
        ds = np.array([side*.235,2.17,0.0]); de=np.array([side*.325,1.62,.025]); dw=np.array([side*.397,.985,.065])
        arm = affine_axis(src, shoulder, elbow, ds,de,.88)
        forearm = affine_axis(src, elbow,wrist,de,dw,.80)
        hand = affine_axis(src,wrist,palm,dw,dw+np.array([side*.012,-.135,.014]),.84)
        for g, transformed in enumerate([arm,forearm,hand]):
            v += group_weights[:,offset+g,None] * (transformed-general)
    # Fit the real cervical skin to a smooth neck under the collar. This keeps
    # the original Anny connectivity while removing retargeted jaw/throat folds.
    for i,p in enumerate(v):
        if p[1]>2.23 and arm_w[i]<.05:
            amount=np.clip((p[1]-2.23)/.055,0,1)
            theta=np.arctan2(p[2]-.012,p[0])
            rx=np.interp(p[1],[2.23,2.35],[.067,.054])
            rz=np.interp(p[1],[2.23,2.35],[.058,.047])
            target=np.array([np.cos(theta)*rx,.012+np.sin(theta)*rz])
            v[i,[0,2]]=p[[0,2]]*(1-amount)+target*amount
    # Anatomical body is one shared vertex mesh, including palms/fingers/neck.
    tags = np.zeros(len(v),int); blend = np.ones(len(v))
    for side, suffix, offset in [(1,'.L',0),(-1,'.R',3)]:
        a = group_weights[:,offset:offset+3].sum(1)
        mask=a>.008; tags[mask]=3 if side>0 else 2; blend[mask]=a[mask]
        ids=[i for i,l in enumerate(labels) if l.endswith(suffix) and l.startswith(('upperleg','lowerleg','foot','toe'))]
        leg_w=(w*np.isin(indices,ids)).sum(1);mask=(leg_w>.008)&(arm_w<.008)
        tags[mask]=5 if side>0 else 4;blend[mask]=leg_w[mask]
    mask=(v[:,1]>2.29)&(arm_w<.01);tags[mask]=1;blend[mask]=np.clip((v[mask,1]-2.29)/.10,0,1)
    v,f,tags,blend=clip_neck(v,f,tags,blend)
    # Internal oral/throat pieces can remain below a neck cut. They are not part
    # of the exterior body and must not become floating sealed components.
    clipped=trimesh.Trimesh(v,f,process=False)
    components=trimesh.graph.connected_components(clipped.face_adjacency, nodes=np.arange(len(f)))
    f=f[max(components,key=len)]
    v,f,tags,blend=compact(v,f,tags,blend)
    ring=connected_boundary(f,v)
    # Make the preserved faceless skull an actual continuation of the neck ring,
    # not another intersecting sphere. Ring indices are shared, not duplicated.
    # Regularize the cut neck to an ordered ring before attaching the skull.
    # Raw neck/jaw contours can backtrack in polar angle; copying those angles
    # into every skull ring would create overlapping triangles at the chin.
    q=v[ring][:,[0,2]]
    area=np.sum(q[:,0]*np.roll(q[:,1],-1)-q[:,1]*np.roll(q[:,0],-1))
    length=np.linalg.norm(np.roll(q,-1,axis=0)-q,axis=1)
    fraction=np.concatenate([[0],np.cumsum(length[:-1])])/length.sum()
    angle=np.arctan2(q[0,1]-.012,q[0,0])+(1 if area>0 else -1)*fraction*2*np.pi
    v[ring,0]=np.cos(angle)*.054;v[ring,2]=.012+np.sin(angle)*.047
    previous=list(ring)
    verts=list(v); regions=list(tags); blends=list(blend); faces=list(f)
    for y,r in [(2.367,.061),(2.407,.103),(2.475,.139),(2.555,.160),(2.635,.165),(2.700,.139),(2.752,.087),(2.772,.008)]:
        current=[]
        for a in angle:
            current.append(len(verts));verts.append([np.cos(a)*r,y,.022+np.sin(a)*r*.85]);regions.append(1);blends.append(float(np.clip((y-2.29)/.10,0,1)))
        for i in range(len(ring)):
            j=(i+1)%len(ring)
            # Winding repaired consistently by trimesh below.
            faces.extend([[previous[i],previous[j],current[i]],[previous[j],current[j],current[i]]])
        previous=current
    top=len(verts);verts.append([0,2.773,.022]);regions.append(1);blends.append(1.)
    for i in range(len(ring)):faces.append([previous[i],previous[(i+1)%len(ring)],top])
    v=np.array(verts);f=np.array(faces);tags=np.array(regions);blend=np.array(blends)
    body=trimesh.Trimesh(v,f,process=False);body.fix_normals(multibody=True)
    f=body.faces.copy(); n=normals(v,f)
    assert len(body.split(only_watertight=False))==1, 'Body/head must be one connected component'
    assert body.is_watertight, 'Continuous anatomical skin must have no boundary edges'
    # Fitted garments inherit identical vertex labels/weights at every seam.
    jacket=v+n*.021
    # Fit a tailored, gently flared shell rather than painting the naked anatomy
    # black. Smooth torso sections retain Anny's continuous shoulder topology.
    for i,p in enumerate(v):
        arm_influence=blend[i] if tags[i] in [2,3] else 0.0
        torso_weight=1.0-np.clip(arm_influence*1.8,0,1)
        if 1.28<p[1]<2.30 and torso_weight>.01:
            rx=np.interp(p[1],[1.28,1.50,1.75,2.0,2.13,2.30],[.184,.174,.173,.213,.239,.095])
            rz=np.interp(p[1],[1.28,1.75,2.13,2.30],[.134,.133,.152,.075])
            r=np.sqrt((p[0]/rx)**2+(p[2]/rz)**2)
            if r>.01:
                fitted=p[[0,2]]/min(r,1.0)+n[i,[0,2]]*.023
                jacket[i,[0,2]]=jacket[i,[0,2]]*(1-torso_weight)+fitted*torso_weight
    pants=v+n*.014
    shirt=v+n*.009
    face_sets=[(3,v,f,tags,blend)]
    jfaces=[];pfaces=[];shirtfaces=[]
    for face in f:
        c=v[face].mean(0)
        arm_influence=np.mean([blend[i] if tags[i] in [2,3] else 0 for i in face])
        arm=arm_influence>.35
        if c[1]<1.44 and not arm and c[1]>=.105:pfaces.append(face)
        torso=(1.30<c[1]<2.325 and not arm)
        if (torso or (arm and c[1]>1.02)):
            jfaces.append(face)
        if 1.75<c[1]<2.305 and not arm:shirtfaces.append(face)
    # Straight garment hem: only the lower jacket boundary is flattened. Sleeve
    # openings stay fitted to the real wrists; no separate sleeve cylinders.
    jf=np.array(jfaces)
    e=np.sort(np.concatenate([jf[:,[0,1]],jf[:,[1,2]],jf[:,[2,0]]]),1)
    edge,counts=np.unique(e,axis=0,return_counts=True)
    for i in np.unique(edge[counts==1]):
        if v[i,1]<1.43 and (tags[i] not in [2,3] or blend[i]<.35):
            jacket[i,1]=1.285
    jacket,jf,jtags,jweights=clip_jacket(jacket,jf,tags,blend)
    face_sets += [(0,jacket,jf,jtags,jweights),(0,pants,np.array(pfaces),tags,blend),(2,shirt,np.array(shirtfaces),tags,blend)]
    batches=[]
    for mat,positions,faces,local_tags,local_blend in face_sets:
        nn=normals(positions,faces)
        # Normal of a garment boundary remains smooth via complete-body fallback.
        missing=np.linalg.norm(nn,axis=1)<.5;nn[missing]=[0,0,1]
        used, inv=np.unique(faces,return_inverse=True)
        batches.append(dict(material=mat,vertices=np.round(positions[used],7).tolist(),normals=np.round(nn[used],7).tolist(),
                            regions=local_tags[used].tolist(),weights=np.round(np.clip(local_blend[used],0,1),7).tolist(),faces=inv.reshape(-1,3).tolist()))
    result=dict(generator='Anny 0.6.2 / free anny-notongue topology',source='https://github.com/naver/anny',
        phenotype=dict(gender=1,age=.45,weight=.18,muscle=.22,height=.9,proportions=.5),
        license='MakeHuman-derived anatomical data CC0-1.0; Anny code Apache-2.0',
        body_vertices=len(v),body_triangles=len(f),body_watertight=bool(body.is_watertight),body_components=1,
        neck_ring=ring,body_faces=f.tolist(),body_positions=np.round(v,7).tolist(),batches=batches)
    OUT.parent.mkdir(exist_ok=True,parents=True);OUT.write_text(json.dumps(result,separators=(',',':')))
    print('BAKED',OUT,'body',len(v),len(f),'total',sum(len(x['faces']) for x in batches),'triangles')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--source',type=Path,default=ROOT/'tools/dl/anny_neutral.npz');p.add_argument('--regenerate-source',action='store_true');a=p.parse_args()
    if a.regenerate_source or not a.source.exists():
        a.source.parent.mkdir(parents=True,exist_ok=True);generate_source(a.source)
    bake(a.source)
