// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright DroidVM contributors
// Additional permissions apply; see ADDITIONAL-PERMISSIONS in the repository root.
package cn.classfun.droidvm.lib.data;

/**
 * qemu-system-aarch64 (Gunyah accelerator) process exit codes that VMInstance gives special
 * handling, beyond "zero is clean, nonzero is a failure." Mirrors {@link CrosvmExit}'s shape
 * for the other backend, but these codes are QEMU's own (see qemu-gunyah-fork's
 * include/system/gunyah.h) and are not comparable to crosvm's.
 */
public enum QemuExit {
    /**
     * GUNYAH_VM_START_RETRY_STATUS: GH_VM_START failed with ENODEV, i.e. the Gunyah Resource
     * Manager rejected VM_INIT. Measured on real hardware (qemu-gunyah-fork's
     * HANDOFF_README.md, sections 14-19), this correlates with how little time has elapsed
     * since the previous VM's teardown: the hypervisor frees a destroyed VM's objects
     * (doorbells, vCPU threads, address spaces, cap tables) through an RCU grace period, and a
     * new VM's VM_INIT can race that reclaim. A bounded, backed-off retry resolved the failure
     * every time in on-device testing (20/20 runs recovered, vs. a 10% raw failure rate without
     * it). It must stay bounded: the Resource Manager reports every vdevice-creation failure
     * identically, so a genuinely permanent rejection (e.g. more vCPUs than the platform has
     * cores) exits the same way and would otherwise be retried forever.
     */
    GUNYAH_VM_START_RETRY(83);

    private final int code;

    QemuExit(int code) {
        this.code = code;
    }

    public int getCode() {
        return code;
    }

    /** Maps a raw qemu-system-aarch64 exit code to its constant, or null when unrecognized. */
    public static QemuExit fromCode(int code) {
        for (QemuExit exit : values()) {
            if (exit.code == code) {
                return exit;
            }
        }
        return null;
    }
}
