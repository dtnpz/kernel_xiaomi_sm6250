#!/usr/bin/env python3
from pathlib import Path

p = Path("KernelSU/kernel/manager/throne_tracker.c")
s = p.read_text()

start = s.find('static DEFINE_MUTEX(throne_tracker_mutex);')
if start < 0:
    raise SystemExit('[N45][xxKSU-throne] start marker not found')

end_marker = '''void ksu_throne_tracker_exit()\n{\n\t// nothing to do\n}\n'''
end = s.find(end_marker, start)
if end < 0:
    raise SystemExit('[N45][xxKSU-throne] end marker not found')
end += len(end_marker)

old = s[start:end]
if old.count('kthread_run(throne_tracker_thread') != 1:
    raise SystemExit('[N45][xxKSU-throne] unexpected upstream thread layout')
if 'set_user_nice(current, -10);' not in old:
    raise SystemExit('[N45][xxKSU-throne] expected upstream -10 nice boost missing')
if 'is_file_existing("/data/system/packages.list.tmp")' not in old:
    raise SystemExit('[N45][xxKSU-throne] packages.list.tmp stability loop missing')
if 'is_file_stable(SYSTEM_PACKAGES_LIST_PATH)' not in old:
    raise SystemExit('[N45][xxKSU-throne] packages.list stability loop missing')

new = r'''static DEFINE_MUTEX(throne_tracker_mutex);
static atomic_t throne_tracker_running = ATOMIC_INIT(0);
static atomic_t throne_tracker_pending = ATOMIC_INIT(0);
static atomic_t throne_tracker_need_full = ATOMIC_INIT(0);

/*
 * N45 / Linux 4.14 scheduling adapter for xxKSU 32602.
 *
 * Keep throne_tracker_fn() and all manager/crown semantics exactly upstream.
 * Only serialize the expensive scan scheduling:
 *   - never run the first scan in the system_server caller;
 *   - never create a high-priority (-10 nice) thread per packages.list event;
 *   - collapse event bursts into one active worker plus at most one follow-up;
 *   - preserve upstream's unbounded wait for packages.list to become stable,
 *     so manager discovery is never silently dropped during a slow boot.
 */
static int throne_tracker_thread(void *unused)
{
	pr_info("throne_tracker: single-flight worker pid: %d started\n", current->pid);

	/* Manager discovery is background work; do not compete with SystemUI/RIL. */
	set_user_nice(current, 10);
	escape_to_root_forced();

	for (;;) {
		bool prune_only;

		/* Consume this batch. New events set pending again while we work. */
		atomic_set(&throne_tracker_pending, 0);
		prune_only = atomic_xchg(&throne_tracker_need_full, 0) ? false : true;

		/* Preserve xxKSU's original readiness semantics: wait, never drop. */
test_tmp:
		if (!is_file_existing("/data/system/packages.list.tmp"))
			goto test_list;

		if (IS_ENABLED(CONFIG_KSU_DEBUG))
			pr_info("throne_tracker: rename not finished! retry!\n");

		msleep(20);
		goto test_tmp;

test_list:
		if (is_file_stable(SYSTEM_PACKAGES_LIST_PATH))
			goto start_tt;

		if (IS_ENABLED(CONFIG_KSU_DEBUG))
			pr_info("throne_tracker: packages.list not stable! retry!\n");

		msleep(20);
		goto test_list;

start_tt:
		mutex_lock(&throne_tracker_mutex);
		throne_tracker_fn(prune_only);
		mutex_unlock(&throne_tracker_mutex);

		if (!atomic_read(&throne_tracker_pending))
			break;
	}

	/*
	 * Release ownership, then close the trigger-vs-exit race. If an event
	 * arrived while running was still 1, we are responsible for restarting.
	 */
	atomic_set(&throne_tracker_running, 0);
	if (atomic_read(&throne_tracker_pending) &&
	    atomic_cmpxchg(&throne_tracker_running, 0, 1) == 0) {
		struct task_struct *task;

		task = kthread_run(throne_tracker_thread, NULL, "ksu_throne");
		if (IS_ERR(task)) {
			pr_err("throne_tracker: restart failed: %ld\n", PTR_ERR(task));
			atomic_set(&throne_tracker_running, 0);
		}
	}

	pr_info("throne_tracker: single-flight worker exit\n");
	return 0;
}

void track_throne(bool prune_only)
{
	struct task_struct *task;

	/* Full manager discovery dominates prune-only work in the same batch. */
	if (!prune_only)
		atomic_set(&throne_tracker_need_full, 1);
	atomic_set(&throne_tracker_pending, 1);

	/* One worker owns all queued throne scans. */
	if (atomic_cmpxchg(&throne_tracker_running, 0, 1) != 0)
		return;

	task = kthread_run(throne_tracker_thread, NULL, "ksu_throne");
	if (IS_ERR(task)) {
		pr_err("throne_tracker: failed to start worker: %ld\n", PTR_ERR(task));
		atomic_set(&throne_tracker_running, 0);
		/* Keep pending set so a later observer event can retry discovery. */
	}
}

void ksu_throne_tracker_init()
{
	// Worker is created on demand by the first packages.list event.
}

void ksu_throne_tracker_exit()
{
	// N45 integrates KernelSU in-tree; there is no module-unload path here.
}
'''

s = s[:start] + new + s[end:]
p.write_text(s)

checks = [
    'atomic_t throne_tracker_running = ATOMIC_INIT(0)',
    'set_user_nice(current, 10);',
    'atomic_cmpxchg(&throne_tracker_running, 0, 1)',
    'is_file_existing("/data/system/packages.list.tmp")',
    'is_file_stable(SYSTEM_PACKAGES_LIST_PATH)',
    'throne_tracker_fn(prune_only);',
]
for marker in checks:
    if marker not in s:
        raise SystemExit(f'[N45][xxKSU-throne] missing generated marker: {marker}')

if 'kthread_run(throne_tracker_thread, (void *)prune_only' in s:
    raise SystemExit('[N45][xxKSU-throne] per-event upstream kthread path still present')
if 'set_user_nice(current, -10);' in s:
    raise SystemExit('[N45][xxKSU-throne] high-priority scan path still present')
if 'packages.list did not stabilize; deferring scan' in s:
    raise SystemExit('[N45][xxKSU-throne] bounded/drop-on-timeout path still present')

print('[N45][xxKSU-throne] installed conservative async single-flight scheduler')
