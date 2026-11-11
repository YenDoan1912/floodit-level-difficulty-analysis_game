import pandas as pd, numpy as np, json
from scipy.stats import spearmanr
d=pd.read_csv('data/daily_overview.csv'); c=pd.read_csv('data/cohort_retention.csv'); dr=pd.read_csv('data/level_dropoff.csv')
L=pd.read_csv('data/level_difficulty.csv').merge(pd.read_csv('data/level_extra_steps.csv'),on='level')
L=L.merge(dr,on='level',how='left')
# pooled retention
for k in ['d1','d3','d7']: c[k+'_n']=(c[k+'_pct']*c.cohort_size/100).round()
pool={k:round(c[k+'_n'].sum()/c.cohort_size.sum()*100,2) for k in ['d1','d3','d7']}
print('pooled',pool,'N',c.cohort_size.sum(),'cohorts',len(c))
c['week']=pd.to_datetime(c.install_date).dt.to_period('W').dt.start_time
wk=c.groupby('week').agg(n=('cohort_size','sum'),d1=('d1_n','sum'),d7=('d7_n','sum')).reset_index()
wk['d1p']=wk.d1/wk.n*100; wk['d7p']=wk.d7/wk.n*100
print(wk.round(1).to_string())
# spike vs neighbours median (window 5 excluding self)
L=L[L.level.between(1,30)].reset_index(drop=True)
base=[]
for i in range(len(L)):
    nb=L.drop_rate_pct.iloc[max(0,i-3):i].tolist()+L.drop_rate_pct.iloc[i+1:i+4].tolist()
    base.append(np.median(nb))
L['drop_base']=base; L['drop_excess']=L.drop_rate_pct-L.drop_base
# helper uses absolute per level (all users)
L['help_n']=L.extra_steps*L.so_lan_thu/100
L['help_per_player']=L.help_n/L.so_nguoi_choi
# future helper uses for a new player who has reached level L+1: sum_k>L P(reach k | reach L+1)*help_per_player_k
reach=L.set_index('level').so_nguoi_toi
fut={}
for l in L.level:
    ks=[k for k in L.level if k>l]
    if not ks: fut[l]=0; continue
    r0=reach.get(l+1,np.nan)
    fut[l]=sum(reach[k]/r0*L.set_index('level').help_per_player[k] for k in ks)
L['future_help']=L.level.map(fut)
# baseline helper rate (neighbour median) -> extra helper from difficulty
hb=[]
for i in range(len(L)):
    nb=L.extra_steps.iloc[max(0,i-3):i].tolist()+L.extra_steps.iloc[i+1:i+4].tolist()
    hb.append(np.median(nb))
L['help_base']=hb
L['help_extra']=(L.extra_steps-L.help_base)*L.so_lan_thu/100
L['lost_players']=L.drop_excess.clip(lower=0)*L.so_nguoi_toi/100
L['lost_help']=L.lost_players*L.future_help
L['net']=L.help_extra-L.lost_help
pd.set_option('display.width',250)
print(L[['level','win_rate_pct','drop_rate_pct','drop_base','drop_excess','extra_steps','help_base','help_extra','lost_players','future_help','lost_help','net']].round(2).to_string())
print('spearman win~drop',spearmanr(L.win_rate_pct,L.drop_rate_pct))
print('spearman win~help',spearmanr(L.win_rate_pct,L.extra_steps))
print('spearman win~drop excluding 1-4',spearmanr(L.win_rate_pct[4:],L.drop_rate_pct[4:]))
L.to_csv('data/levels_all.csv',index=False)
json.dump(pool,open('data/pool.json','w'))
