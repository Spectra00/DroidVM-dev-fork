// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright DroidVM contributors
// Additional permissions apply; see ADDITIONAL-PERMISSIONS in the repository root.
package cn.classfun.droidvm.daemon.vm.backend;

import androidx.annotation.NonNull;

import java.io.FileInputStream;
import java.io.IOException;

import cn.classfun.droidvm.ui.disk.create.DiskFormat;

/**
 * The QEMU block driver name ({@code format=}) for a disk image.
 *
 * <p>QEMU's {@code -drive} without {@code format=} probes the file, and when no compiled-in
 * driver claims it the probe falls back to {@code raw}: a qcow2 then reaches the guest as its
 * container bytes, so the guest finds no partition table and waits for its root device forever.
 * The QEMU build also warns that probing is unsafe for raw images. Every drive therefore names
 * its format, read from the image header so a misnamed file is still opened correctly, and from
 * the extension only when the header cannot be read.</p>
 */
final class QemuDiskFormat {
    static final String RAW = "raw";
    static final String QCOW2 = "qcow2";
    static final String VHDX = "vhdx";
    static final String VDI = "vdi";
    static final String VMDK = "vmdk";

    /** Bytes of header needed by {@link #fromHeader}: the VDI signature sits at 0x40. */
    static final int HEADER_BYTES = 0x44;

    private QemuDiskFormat() {
    }

    /** The driver for the image at [path], from its header, else from its extension. */
    @NonNull
    static String detect(@NonNull String path) {
        var head = new byte[HEADER_BYTES];
        int len = 0;
        try (var in = new FileInputStream(path)) {
            while (len < head.length) {
                int n = in.read(head, len, head.length - len);
                if (n < 0) break;
                len += n;
            }
        } catch (IOException e) {
            return fromExtension(path);
        }
        return fromHeader(head, len);
    }

    /**
     * The driver whose magic opens [head]; {@code raw} for anything else, ISO images included.
     * Only the formats DroidVM can create or import are recognised.
     */
    @NonNull
    static String fromHeader(@NonNull byte[] head, int len) {
        if (startsWith(head, len, 0, new byte[]{'Q', 'F', 'I', (byte) 0xfb}))
            return QCOW2;
        if (startsWith(head, len, 0, new byte[]{'v', 'h', 'd', 'x', 'f', 'i', 'l', 'e'}))
            return VHDX;
        if (startsWith(head, len, 0, new byte[]{'K', 'D', 'M', 'V'}))
            return VMDK;
        // VDI: little-endian 0xbeda107f at offset 0x40
        if (startsWith(head, len, 0x40, new byte[]{0x7f, 0x10, (byte) 0xda, (byte) 0xbe}))
            return VDI;
        return RAW;
    }

    /** The driver the app's own extension convention ({@link DiskFormat}) implies. */
    @NonNull
    static String fromExtension(@NonNull String path) {
        switch (DiskFormat.fromFilename(path)) {
            case QCOW2: return QCOW2;
            case VHDX: return VHDX;
            case VDI: return VDI;
            case VMDK: return VMDK;
            default: return RAW;
        }
    }

    private static boolean startsWith(byte[] head, int len, int off, byte[] magic) {
        if (off + magic.length > len) return false;
        for (int i = 0; i < magic.length; i++)
            if (head[off + i] != magic[i]) return false;
        return true;
    }
}
