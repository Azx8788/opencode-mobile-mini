package com.termux.terminal;

/**
 * Public access to the PTY calls of Termux's Apache 2.0 terminal-emulator
 * library (com.github.termux.termux-app:terminal-emulator), whose JNI class is
 * package-private. The native code (termux.c) opens a pseudoterminal, forks,
 * and executes the program on it; nothing else of Termux is used here.
 *
 * Written for this app (MIT); it only forwards to the library. The local
 * terminal (LocalTerminal.kt) is its one user.
 */
public final class PtyAccess {
    private PtyAccess() {}

    /**
     * Starts [cmd] with [args] (argv, argv[0] included) and exactly [env] on
     * a new PTY of [rows] x [columns]. Returns the PTY master's file
     * descriptor; the child's pid lands in processId[0].
     */
    public static int createSubprocess(
            String cmd,
            String cwd,
            String[] args,
            String[] env,
            int[] processId,
            int rows,
            int columns,
            int cellWidth,
            int cellHeight) {
        return JNI.createSubprocess(cmd, cwd, args, env, processId, rows, columns, cellWidth, cellHeight);
    }

    public static void setPtyWindowSize(int fd, int rows, int columns, int cellWidth, int cellHeight) {
        JNI.setPtyWindowSize(fd, rows, columns, cellWidth, cellHeight);
    }

    /** Blocks until [processId] ends; its exit code, or minus the signal that ended it. */
    public static int waitFor(int processId) {
        return JNI.waitFor(processId);
    }

    public static void close(int fd) {
        JNI.close(fd);
    }
}
