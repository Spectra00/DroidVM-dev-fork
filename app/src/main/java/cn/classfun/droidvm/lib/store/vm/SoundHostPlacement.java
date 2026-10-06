// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright DroidVM contributors
// Additional permissions apply; see ADDITIONAL-PERMISSIONS in the repository root.
package cn.classfun.droidvm.lib.store.vm;

import androidx.annotation.NonNull;

import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.NavigableMap;
import java.util.TreeMap;
import java.util.TreeSet;

import cn.classfun.droidvm.lib.store.base.DataItem;
import cn.classfun.droidvm.lib.utils.CpuUtils;

/**
 * Which host cores crosvm's virtio-snd backend process ({@code device snd}) should run on.
 *
 * <p>The sound device runs as its own process, re-executed under the app's uid, and by default it
 * may run on every core -- the same cores the vCPUs and the GPU worker were pinned to. Measured on
 * an Adreno 840 phone with a Proton game: with the vCPUs pinned one per core, the sound process
 * still sharing those cores and PipeWire at its default quantum, playback was choppy; moved to
 * the cores nothing else was pinned to, and given a low real-time priority, it was clean.</p>
 *
 * <p>The rule is "the cores the VM left free": every host core that is neither a vCPU's nor in
 * the GPU worker cpuset, keeping only the little ones when there are any (the sound path needs
 * steady scheduling, not peak speed, and the big cores are where heat comes from). With no vCPU
 * pinned there is nothing to stay out of the way of, so no placement is made at all.</p>
 */
public final class SoundHostPlacement {
    /** SCHED_FIFO level for the sound process's main thread: low among real-time levels. */
    public static final int RT_PRIO = 10;

    private SoundHostPlacement() {
    }

    /** The cores for this VM's sound process on this host; empty means leave it unpinned. */
    @NonNull
    public static List<Integer> cores(@NonNull DataItem item, @NonNull List<CpuUtils.CpuCore> host) {
        var taken = new TreeSet<Integer>();
        for (var hosts : CpuPlacementPlan.of(item).affinity.values()) taken.addAll(hosts);
        if (taken.isEmpty()) return new ArrayList<>();
        if (CpuPlacementPlan.wantsGpuCgroup(item))
            taken.addAll(CpuUtils.parseCpuSet(
                item.optString(CpuPlacementPlan.KEY_GPU_CGROUP_CPUS, "")));
        var bigByCore = new TreeMap<Integer, Boolean>();
        for (var core : host) bigByCore.put(core.index, core.big);
        return pick(bigByCore, taken);
    }

    /**
     * The free cores: those not in {@code taken}, little ones only when any little one is free.
     * Empty when {@code taken} is empty (nothing pinned) or covers every core.
     */
    @NonNull
    public static List<Integer> pick(
        @NonNull NavigableMap<Integer, Boolean> bigByCore,
        @NonNull Collection<Integer> taken
    ) {
        var free = new ArrayList<Integer>();
        var freeLittle = new ArrayList<Integer>();
        if (taken.isEmpty()) return free;
        for (var entry : bigByCore.entrySet()) {
            if (taken.contains(entry.getKey())) continue;
            free.add(entry.getKey());
            if (!entry.getValue()) freeLittle.add(entry.getKey());
        }
        return freeLittle.isEmpty() ? free : freeLittle;
    }
}
