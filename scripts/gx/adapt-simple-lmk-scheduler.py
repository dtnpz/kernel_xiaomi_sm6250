#!/usr/bin/env python3
from pathlib import Path

p = Path("drivers/android/simple_lmk.c")
s = p.read_text()

# Android assigns background music/perceptible foreground-service work
# oom_score_adj=200.  Simple LMK must exhaust ordinary background/cached
# processes before considering anything the user is actively hearing/seeing.
old_victim_floor = """		if (adj < 0 ||
"""
new_victim_floor = """		if (adj <= 200 ||
"""
if old_victim_floor not in s:
    raise SystemExit("simple_lmk victim floor did not match expected source")
s = s.replace(old_victim_floor, new_victim_floor, 1)

old_reclaim = '''static int simple_lmk_reclaim_thread(void *data)
{
	/* Use maximum RT priority */
	set_task_rt_prio(current, MAX_RT_PRIO - 1);
	set_freezable();
'''
new_reclaim = '''static int simple_lmk_reclaim_thread(void *data)
{
	/*
	 * N45 runtime adaptation:
	 * vmpressure=100 can arrive in bursts while Android is starting heavy
	 * apps. #183 proved that removing RR99 prevents the worst starvation,
	 * but its -5 nice level can still outrank normal system_server/Binder/UI
	 * work while reclaim is active. Run the control worker at normal CFS
	 * priority; victim exit threads remain RR1 and still release memory fast.
	 */
	set_user_nice(current, 0);
	set_freezable();
'''

old_reaper = '''static int simple_lmk_reaper_thread(void *data)
{
	/* Use a lower priority than the reclaim thread */
	set_task_rt_prio(current, MAX_RT_PRIO - 2);
	set_freezable();
'''
new_reaper = '''static int simple_lmk_reaper_thread(void *data)
{
	/* Reaping is background work; keep it just below the reclaim worker. */
	set_user_nice(current, 1);
	set_freezable();
'''

if old_reclaim not in s:
    raise SystemExit("simple_lmk reclaim scheduler block did not match expected N45 source")
if old_reaper not in s:
    raise SystemExit("simple_lmk reaper scheduler block did not match expected N45 source")

s = s.replace(old_reclaim, new_reclaim, 1)
s = s.replace(old_reaper, new_reaper, 1)

checks = [
    "set_user_nice(current, 0);",
    "set_user_nice(current, 1);",
    "set_task_rt_prio(t, 1);",
    "if (pressure == 100)",
    "if (adj <= 200 ||",
]
for marker in checks:
    if marker not in s:
        raise SystemExit(f"simple_lmk adaptation validation failed: missing {marker!r}")

if "set_task_rt_prio(current, MAX_RT_PRIO - 1);" in s:
    raise SystemExit("simple_lmk reclaim thread still uses RR99")
if "set_task_rt_prio(current, MAX_RT_PRIO - 2);" in s:
    raise SystemExit("simple_lmk reaper thread still uses RR98")
if "if (adj < 0 ||" in s:
    raise SystemExit("simple_lmk still allows perceptible/foreground victims")

p.write_text(s)
print("[N45] adapted Simple LMK: CFS control workers + protect oom_score_adj <= 200")
