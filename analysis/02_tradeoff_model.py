import pandas as pd, numpy as np, json
L=pd.read_csv('data/levels_all.csv')
L['stage']=pd.cut(L.level,[0,10,20,30],labels=['1–10','11–20','21–30'])
ref=L[L.win_rate_pct>=90].groupby('stage',observed=True).agg(drop_ref=('drop_rate_pct','median'),help_ref=('extra_steps','median'))
print(ref)
L=L.join(ref,on='stage')
L['drop_ex']=(L.drop_rate_pct-L.drop_ref).clip(lower=0)
L['lost']=L.drop_ex*L.so_nguoi_toi/100
L['help_ex']=(L.extra_steps-L.help_ref)*L.so_lan_thu/100
res=[]
for k in [1,2,3]:
    L[f'net_k{k}']=L.help_ex-L.lost*L.future_help*k
hard=L[L.win_rate_pct<75]
cols=['level','win_rate_pct','drop_rate_pct','drop_ref','lost','extra_steps','help_ref','help_ex','future_help','net_k1','net_k2','net_k3']
print(hard[cols].round(1).to_string())
blk={'5–9':range(5,10),'18–20':range(18,21),'25–27':range(25,28),'29–30':range(29,31)}
for n,r in blk.items():
    s=L[L.level.isin(r)]
    print(n,'lost',round(s.lost.sum()),'help_ex',round(s.help_ex.sum()),[round(s[f'net_k{k}'].sum()) for k in [1,2,3]])
L.to_csv('data/levels_all.csv',index=False)
