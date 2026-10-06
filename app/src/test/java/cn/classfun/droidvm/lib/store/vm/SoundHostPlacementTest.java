// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright DroidVM contributors
// Additional permissions apply; see ADDITIONAL-PERMISSIONS in the repository root.
package cn.classfun.droidvm.lib.store.vm;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.util.List;
import java.util.Set;
import java.util.TreeMap;

/** Where the virtio-snd process goes: the cores the VM left free, little ones first. */
public final class SoundHostPlacementTest {
    /** 8 cores: 0-5 little, 6-7 big (the Adreno 840 phone's layout). */
    private static TreeMap<Integer, Boolean> eightCores() {
        var m = new TreeMap<Integer, Boolean>();
        for (int i = 0; i < 8; i++) m.put(i, i >= 6);
        return m;
    }

    @Test
    public void vcpusOnTwoToFiveAndGpuOnSevenLeavesLittleZeroOne() {
        // core 6 is free too, but big: the little free cores win
        assertEquals(List.of(0, 1),
            SoundHostPlacement.pick(eightCores(), Set.of(2, 3, 4, 5, 7)));
    }

    @Test
    public void onlyBigCoresFreeStillPlaces() {
        assertEquals(List.of(6, 7),
            SoundHostPlacement.pick(eightCores(), Set.of(0, 1, 2, 3, 4, 5)));
    }

    @Test
    public void nothingPinnedMeansNoPlacement() {
        assertTrue(SoundHostPlacement.pick(eightCores(), Set.of()).isEmpty());
    }

    @Test
    public void everyCoreTakenMeansNoPlacement() {
        assertTrue(SoundHostPlacement.pick(eightCores(),
            Set.of(0, 1, 2, 3, 4, 5, 6, 7)).isEmpty());
    }

    @Test
    public void singleClusterUsesAllFreeCores() {
        var m = new TreeMap<Integer, Boolean>();
        for (int i = 0; i < 4; i++) m.put(i, false);
        assertEquals(List.of(0, 3), SoundHostPlacement.pick(m, Set.of(1, 2)));
    }
}
