// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright DroidVM contributors
// Additional permissions apply; see ADDITIONAL-PERMISSIONS in the repository root.
package cn.classfun.droidvm.ui.vm.display.nativedisplay.input;

import android.content.Context;
import android.util.AttributeSet;
import android.view.KeyEvent;
import android.widget.FrameLayout;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

/**
 * The native display's container, able to take key events before the framework's own key
 * handling sees them.
 *
 * <p>Between the IME and {@code dispatchKeyEvent}, ViewRootImpl leaves touch mode on any key from
 * a keyboard. For a typing key that makes the focused view draw its focus highlight, which over
 * a display is a tint across the whole guest screen on every key press. For a navigation key
 * (DPAD, TAB, PAGE_UP ...) it is worse: the first press after any touch is consumed just to leave
 * touch mode, and later presses move Android's focus instead of reaching the guest. Keys injected
 * by tools such as Key Mapper hit both. The pre-IME pass runs before all of that, so a key the
 * listener takes there never changes touch mode and never navigates focus.</p>
 *
 * <p>The pre-IME pass only reaches a view on the focus path, so this container is made focusable
 * and holds focus while the IME's editor does not.</p>
 */
public final class KeySinkFrameLayout extends FrameLayout {
    /** Returns true when it took the key; the framework then does nothing more with it. */
    public interface PreImeKeyListener {
        boolean onPreImeKey(@NonNull KeyEvent event);
    }

    @Nullable
    private PreImeKeyListener preImeKeyListener;

    public KeySinkFrameLayout(@NonNull Context context) {
        super(context);
    }

    public KeySinkFrameLayout(@NonNull Context context, @Nullable AttributeSet attrs) {
        super(context, attrs);
    }

    public KeySinkFrameLayout(@NonNull Context context, @Nullable AttributeSet attrs,
                              int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }

    public void setPreImeKeyListener(@Nullable PreImeKeyListener listener) {
        this.preImeKeyListener = listener;
    }

    @Override
    public boolean dispatchKeyEventPreIme(@NonNull KeyEvent event) {
        if (preImeKeyListener != null && preImeKeyListener.onPreImeKey(event)) return true;
        return super.dispatchKeyEventPreIme(event);
    }
}
