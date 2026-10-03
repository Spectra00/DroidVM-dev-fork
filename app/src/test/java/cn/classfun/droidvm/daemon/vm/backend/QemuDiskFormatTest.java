// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright DroidVM contributors
// Additional permissions apply; see ADDITIONAL-PERMISSIONS in the repository root.
package cn.classfun.droidvm.daemon.vm.backend;

import static org.junit.Assert.assertEquals;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;

/** The format= each drive gets: from the image header, else from the file name. */
public final class QemuDiskFormatTest {
    @Rule
    public final TemporaryFolder tmp = new TemporaryFolder();

    private static byte[] header(int off, byte... magic) {
        var head = new byte[QemuDiskFormat.HEADER_BYTES];
        System.arraycopy(magic, 0, head, off, magic.length);
        return head;
    }

    private File write(String name, byte[] data) throws IOException {
        var f = tmp.newFile(name);
        try (var out = new FileOutputStream(f)) {
            out.write(data);
        }
        return f;
    }

    @Test
    public void qcow2HeaderIsQcow2() {
        var h = header(0, (byte) 'Q', (byte) 'F', (byte) 'I', (byte) 0xfb,
            (byte) 0, (byte) 0, (byte) 0, (byte) 3);
        assertEquals("qcow2", QemuDiskFormat.fromHeader(h, h.length));
    }

    @Test
    public void otherImageHeaders() {
        var vhdx = header(0, "vhdxfile".getBytes());
        assertEquals("vhdx", QemuDiskFormat.fromHeader(vhdx, vhdx.length));
        var vmdk = header(0, "KDMV".getBytes());
        assertEquals("vmdk", QemuDiskFormat.fromHeader(vmdk, vmdk.length));
        var vdi = header(0x40, (byte) 0x7f, (byte) 0x10, (byte) 0xda, (byte) 0xbe);
        assertEquals("vdi", QemuDiskFormat.fromHeader(vdi, vdi.length));
    }

    @Test
    public void anythingElseIsRaw() {
        var zeros = new byte[QemuDiskFormat.HEADER_BYTES];
        assertEquals("raw", QemuDiskFormat.fromHeader(zeros, zeros.length));
        // a short file cannot match a magic that runs past its end
        var shortQcow = new byte[]{'Q', 'F', 'I'};
        assertEquals("raw", QemuDiskFormat.fromHeader(shortQcow, shortQcow.length));
    }

    @Test
    public void detectReadsTheHeaderNotTheName() throws IOException {
        // a qcow2 named .img still opens as qcow2; a raw image named .qcow2 as raw
        var q = write("disk.img", header(0, (byte) 'Q', (byte) 'F', (byte) 'I', (byte) 0xfb));
        assertEquals("qcow2", QemuDiskFormat.detect(q.getPath()));
        var r = write("disk.qcow2", new byte[4096]);
        assertEquals("raw", QemuDiskFormat.detect(r.getPath()));
    }

    @Test
    public void unreadableFileFallsBackToExtension() {
        var dir = tmp.getRoot();
        assertEquals("qcow2",
            QemuDiskFormat.detect(new File(dir, "missing.qcow2").getPath()));
        assertEquals("raw", QemuDiskFormat.detect(new File(dir, "missing.img").getPath()));
        assertEquals("raw", QemuDiskFormat.detect(new File(dir, "missing.iso").getPath()));
    }
}
