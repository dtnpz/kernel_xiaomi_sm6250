#!/usr/bin/env python3
from pathlib import Path

p = Path("KernelSU/kernel/manager/throne_tracker.c")
s = p.read_text()

if '#include <linux/wait.h>\n' not in s:
    s = '#include <linux/wait.h>\n\n' + s

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

new = r'''static DEFINE_MUTEX(throne_tracker_mutex);
static DECLARE_WAIT_QUEUE_HEAD(throne_tracker_waitq);
static struct task_struct *throne_tracker_task;
static atomic_t throne_tracker_pending = ATOMIC_INIT(0);
static atomic_t throne_tracker_need_full = ATOMIC_INIT(0);

/*
 * packages.list can be rewritten several times during Android boot/package
 * reconciliation.  xxKSU 32602 normally creates one high-priority (-10 nice)
 * kthread per event.  On Miatoll 4.14 that can queue several expensive
 * /data/app scans and starve SystemUI/RIL/power-service work.
 *
 * Keep one low-priority KSU-owned worker instead.  Event bursts collapse to
 * one pending pass, with a second pass only when something changed while the
 * worker was already scanning.  The observer/caller never waits for the scan.
 */
static bool throne_tracker_wait_stable(void)
{
	int retries;

	for (retries = 0; retries < 100; retries++) {
		if (kthread_should_stop())
			return false;

		if (!is_file_existing("/data/system/packages.list.tmp") &&
		    is_file_stable(SYSTEM_PACKAGES_LIST_PATH))
			return true;

		msleep(20);
	}

	pr_warn("throne_tracker: packages.list did not stabilize; deferring scan\n");
	return false;
}

static int throne_tracker_worker(void *unused)
{
	pr_info("throne_tracker: dedicated worker pid: %d started\n", current->pid);

	/* Never let manager discovery compete with SystemUI/RIL during boot. */
	set_user_nice(current, 10);
	escape_to_root_forced();

	for (;;) {
		wait_event_interruptible(throne_tracker_waitq,
			kthread_should_stop() || atomic_read(&throne_tracker_pending));

		if (kthread_should_stop())
			break;

		do {
			bool prune_only;

			/* Consume the current batch.  New triggers set pending again. */
			atomic_set(&throne_tracker_pending, 0);
			prune_only = atomic_xchg(&throne_tracker_need_full, 0) ? false : true;

			if (!throne_tracker_wait_stable())
				continue;

			mutex_lock(&throne_tracker_mutex);
			throne_tracker_fn(prune_only);
			mutex_unlock(&throne_tracker_mutex);
		} while (atomic_xchg(&throne_tracker_pending, 0));
	}

	pr_info("throne_tracker: dedicated worker exit\n");
	return 0;
}

void track_throne(bool prune_only)
{
	/* A full manager scan dominates a prune-only request in the same batch. */
	if (!prune_only)
		atomic_set(&throne_tracker_need_full, 1);

	atomic_set(&throne_tracker_pending, 1);
	wake_up_interruptible(&throne_tracker_waitq);
}

void ksu_throne_tracker_init()
{
	throne_tracker_task = kthread_run(throne_tracker_worker, NULL, "ksu_throne");
	if (IS_ERR(throne_tracker_task)) {
		pr_err("throne_tracker: failed to start dedicated worker: %ld\n",
		       PTR_ERR(throne_tracker_task));
		throne_tracker_task = NULL;
	}
}

void ksu_throne_tracker_exit()
{
	if (throne_tracker_task) {
		kthread_stop(throne_tracker_task);
		throne_tracker_task = NULL;
	}
}
'''

s = s[:start] + new + s[end:]
p.write_text(s)

checks = [
    'DECLARE_WAIT_QUEUE_HEAD(throne_tracker_waitq)',
    'set_user_nice(current, 10);',
    'atomic_t throne_tracker_pending',
    'kthread_run(throne_tracker_worker, NULL, "ksu_throne")',
]
for marker in checks:
    if marker not in s:
        raise SystemExit(f'[N45][xxKSU-throne] missing generated marker: {marker}')

if 'kthread_run(throne_tracker_thread, (void *)prune_only' in s:
    raise SystemExit('[N45][xxKSU-throne] per-event kthread path still present')
if 'set_user_nice(current, -10);' in s:
    raise SystemExit('[N45][xxKSU-throne] high-priority scan path still present')

print('[N45][xxKSU-throne] installed single low-priority coalesced worker')
