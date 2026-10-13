// Runs the original setup_world in Ghidra's emulator and dumps the generated world,
// as ground truth for the Swift port:
//   EmulateWorld <level.dat> <out-dir> <ticks> <world-number>...
// <ticks> is a comma-separated list of tick counts to dump at, e.g. "0,1,10,100".
// A dump at 0 ticks is world<N>.bin, later ones world<N>-t<ticks>.bin. An optional
// trailing "!addr,addr,..." names extra routines (hex) to skip, for comparing
// against a partial port. A world may be given as "<N>@<label>@<actions>": after
// setup, side 0 performs the comma-separated actions and the dumps are named
// world<N><label>.... Actions: r/l x:y raise/lower a corner, q/v/s x:y earthquake,
// volcano, swamp, k knight, f flood, a Armageddon, m/n give both sides 200000/30000 mana, h make side 0's leader very strong, w<N> let the game run to tick N first.
// Each <out-dir>/world<N>.bin holds, in order: altitude (65x65 words), map_tile,
// map_height, map_object (64x64 bytes each), map_visits (64x64 words), map_who (64x64
// bytes), rng_seed (word),
// people table (211 x 22 bytes), both player records (2 x 16 bytes), people count (word),
// both order records (2 x 46 bytes), selected person, tick count, phase (words).
//@category Populous
import java.io.File;
import java.io.FileOutputStream;
import java.nio.file.Files;

import ghidra.app.emulator.EmulatorHelper;
import ghidra.app.script.GhidraScript;
import java.util.HashMap;
import java.util.Map;

import ghidra.program.model.listing.Instruction;

public class EmulateWorld extends GhidraScript {
    static final long A4 = 0x7AB96L;
    static final long BSS_START = 0x74390L, BSS_END = 0x7E0CCL;
    static final long SETUP_WORLD = 0x5EBB6L;
    static final long WORLD_NUMBER = 0x73018L, LEVEL_RECORD = 0x7301AL;
    static final long STACK = 0x100000L, RETURN = 0x5E7C4L;
    // Routines that only load files or draw; skipped.
    static final long[] STUBS = {0x6A388L, 0x6A662L, 0x5F76EL, 0x6A188L, 0x69AF6L /* draw view */, 0x6A6ECL /* swap screens */,
        0x6DC0EL /* sound */,
        0x6A71AL /* sound */, 0x6CD32L /* text */, 0x68CA2L /* end-of-game screen */};
    static final long PROCESS_ORDERS = 0x6B1B2L;
    static final long RAISE_LAND = 0x63A12L, LOWER_LAND = 0x638FCL;
    static final long UPDATE_FLYERS = 0x64B40L, UPDATE_PEOPLE = 0x60B28L, PHASE = 0x74560L;

    /** Runs game ticks up to the given count, as the main loop would. */
    private void runTo(EmulatorHelper emu, Map<Long, Long> farCalls, int[] done, int target, String what)
            throws Exception {
        for (; done[0] < target; done[0]++) {
            byte[] phase = emu.readMemory(toAddr(PHASE), 2);
            emu.writeMemory(toAddr(PHASE), new byte[] {0, (byte) (phase[1] == 0 ? 1 : 0)});
            call(emu, farCalls, UPDATE_FLYERS, new byte[0], what + " tick " + done[0]);
            call(emu, farCalls, UPDATE_PEOPLE, new byte[0], what + " tick " + done[0]);
            call(emu, farCalls, PROCESS_ORDERS, new byte[0], what + " tick " + done[0]);
        }
    }

    /** Calls an original routine with the given argument bytes and runs it to completion. */
    private void call(EmulatorHelper emu, Map<Long, Long> farCalls, long routine, byte[] arguments, String what)
            throws Exception {
        long sp = STACK - 4 - arguments.length;
        byte[] frame = new byte[4 + arguments.length];
        frame[1] = (byte) (RETURN >> 16);
        frame[2] = (byte) (RETURN >> 8);
        frame[3] = (byte) RETURN;
        System.arraycopy(arguments, 0, frame, 4, arguments.length);
        emu.writeMemory(toAddr(sp), frame);
        emu.writeRegister("SP", sp);
        emu.writeRegister(emu.getPCRegister(), routine);
        while (true) {
            if (!emu.run(monitor)) {
                throw new RuntimeException(what + ": emulation fault at "
                        + emu.getExecutionAddress() + ": " + emu.getLastError());
            }
            long pc = emu.getExecutionAddress().getOffset();
            if (pc == RETURN) return;
            if (farCalls.containsKey(pc)) {
                long at = emu.readRegister("SP").longValue() - 4;
                long ret = pc + 4;
                emu.writeMemory(toAddr(at), new byte[] {
                    (byte) (ret >> 24), (byte) (ret >> 16), (byte) (ret >> 8), (byte) ret});
                emu.writeRegister("SP", at);
                emu.writeRegister(emu.getPCRegister(), farCalls.get(pc));
                continue;
            }
            // Return from the stubbed routine without running it.
            long at = emu.readRegister("SP").longValue();
            byte[] ret = emu.readMemory(toAddr(at), 4);
            long target = ((ret[0] & 0xFFL) << 24) | ((ret[1] & 0xFFL) << 16) | ((ret[2] & 0xFFL) << 8) | (ret[3] & 0xFFL);
            emu.writeRegister("SP", at + 4);
            emu.writeRegister("D0", 0);
            emu.writeRegister(emu.getPCRegister(), target);
        }
    }

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        byte[] levels = Files.readAllBytes(new File(args[0]).toPath());
        // Ghidra's 68000 model executes jsr (d16,An) as a call through a pointer, but the
        // real CPU calls the address itself. Every far call here has that form, so each
        // site is intercepted and performed by hand.
        Map<Long, Long> farCalls = new HashMap<>();
        for (Instruction ins : currentProgram.getListing().getInstructions(true)) {
            byte[] b = ins.getBytes();
            if (b.length == 4 && b[0] == 0x4E && (b[1] & 0xFF) == 0xAC) {
                farCalls.put(ins.getAddress().getOffset(), A4 + (short) (((b[2] & 0xFF) << 8) | (b[3] & 0xFF)));
            }
        }

        java.util.List<Integer> dumpAt = new java.util.ArrayList<>();
        for (String t : args[2].split(",")) dumpAt.add(Integer.parseInt(t));
        java.util.List<Long> extraStubs = new java.util.ArrayList<>();
        int worldArgs = args.length;
        if (args[args.length - 1].startsWith("!")) {
            worldArgs--;
            for (String a : args[args.length - 1].substring(1).split(",")) extraStubs.add(Long.parseLong(a, 16));
        }

        for (int i = 3; i < worldArgs; i++) {
            String[] spec = args[i].split("@");
            int world = Integer.parseInt(spec[0]);
            EmulatorHelper emu = new EmulatorHelper(currentProgram);
            try {
                emu.writeMemory(toAddr(BSS_START), new byte[(int) (BSS_END - BSS_START)]);
                emu.writeMemory(toAddr(WORLD_NUMBER), new byte[] {(byte) (world >> 8), (byte) world});
                byte[] record = new byte[10];
                System.arraycopy(levels, world / 25 * 10, record, 0, 10);
                emu.writeMemory(toAddr(LEVEL_RECORD), record);

                for (long stub : STUBS) emu.setBreakpoint(toAddr(stub));
                for (long stub : extraStubs) emu.setBreakpoint(toAddr(stub));
                for (long site : farCalls.keySet()) emu.setBreakpoint(toAddr(site));
                emu.setBreakpoint(toAddr(RETURN));
                emu.writeRegister("A4", A4);

                // setup_world(0, -1): two 16-bit arguments above the return address.
                call(emu, farCalls, SETUP_WORLD, new byte[] {0, 0, (byte) 0xFF, (byte) 0xFF}, "world " + world);

                // load_land is skipped above, so put the land file's rule tables where
                // it would have: walk cost, the four 11-word tables, then the three bounties.
                int terrain = levels[world / 25 * 10 + 5];
                byte[] land = Files.readAllBytes(new File(new File(args[0]).getParentFile(), "land" + terrain).toPath());
                emu.writeMemory(toAddr(0x7DAF6L), java.util.Arrays.copyOfRange(land, 0, 2));
                emu.writeMemory(toAddr(0x7DB28L), java.util.Arrays.copyOfRange(land, 2, 24));
                emu.writeMemory(toAddr(0x7DAFCL), java.util.Arrays.copyOfRange(land, 24, 46));
                emu.writeMemory(toAddr(0x7DB12L), java.util.Arrays.copyOfRange(land, 46, 68));
                emu.writeMemory(toAddr(0x7DB40L), java.util.Arrays.copyOfRange(land, 68, 90));
                emu.writeMemory(toAddr(0x7DB56L), java.util.Arrays.copyOfRange(land, 90, 96));

                int[] done = {0};
                if (spec.length > 1) {
                    for (String action : spec[2].split(",")) {
                        char kind = action.charAt(0);
                        byte[] none = {0, 0};
                        String what = "world " + world + " " + action;
                        if (kind == 'w') {
                            // Let the game run to the given tick before going on.
                            runTo(emu, farCalls, done, Integer.parseInt(action.substring(1)), "world " + world);
                        } else if (kind == 'm' || kind == 'n') {
                            // Make both sides rich: 200000 mana (any power) or 30000.
                            byte[] mana = kind == 'm' ? new byte[] {0, 3, 0x0D, 0x40} : new byte[] {0, 0, 0x75, 0x30};
                            emu.writeMemory(toAddr(0x74548L), mana);
                            emu.writeMemory(toAddr(0x74558L), mana);
                        } else if (kind == 'h') {
                            // Make side 0's leader very strong (life 20000).
                            byte[] leader = emu.readMemory(toAddr(0x7453CL), 2);
                            int index = (((leader[0] & 0xFF) << 8) | (leader[1] & 0xFF)) - 1;
                            if (index >= 0) emu.writeMemory(toAddr(0x7476CL + index * 22 + 4), new byte[] {0x4E, 0x20});
                        } else if (kind == 'k') {
                            call(emu, farCalls, 0x6487EL, none, what);
                        } else if (kind == 'f') {
                            call(emu, farCalls, 0x63F0AL, none, what);
                        } else if (kind == 'a') {
                            call(emu, farCalls, 0x64982L, none, what);
                        } else {
                            String[] xy = action.substring(1).split(":");
                            byte[] arguments = {0, 0, 0, (byte) Integer.parseInt(xy[0]), 0, (byte) Integer.parseInt(xy[1])};
                            long routine = kind == 'r' ? RAISE_LAND : kind == 'l' ? LOWER_LAND
                                : kind == 'q' ? 0x64234L : kind == 'v' ? 0x6446CL : 0x64756L;
                            call(emu, farCalls, routine, arguments, what);
                        }
                    }
                }

                // Run game ticks the way the main loop does: flip the animation phase,
                // then update flyers and people and carry out orders. Dump at each requested tick count.
                for (int target : dumpAt) {
                    if (target < done[0]) continue;
                    runTo(emu, farCalls, done, target, "world " + world);
                    String name = "world" + world + (spec.length > 1 ? spec[1] : "") + (target > 0 ? "-t" + target : "") + ".bin";
                    try (FileOutputStream out = new FileOutputStream(new File(args[1], name))) {
                        out.write(emu.readMemory(toAddr(0x759CCL), 65 * 65 * 2));
                        for (long layer : new long[] {0x77ACEL, 0x78ACEL, 0x79ACEL}) {
                            out.write(emu.readMemory(toAddr(layer), 4096));
                        }
                        out.write(emu.readMemory(toAddr(0x7AACEL), 8192));
                        out.write(emu.readMemory(toAddr(0x7CACEL), 4096));
                        out.write(emu.readMemory(toAddr(0x74528L), 2));
                        out.write(emu.readMemory(toAddr(0x7476CL), 211 * 22));
                        out.write(emu.readMemory(toAddr(0x7453CL), 32));
                        out.write(emu.readMemory(toAddr(0x759A4L), 2));
                        out.write(emu.readMemory(toAddr(0x72E14L), 92));
                        out.write(emu.readMemory(toAddr(0x759AEL), 2));
                        out.write(emu.readMemory(toAddr(0x759B0L), 2));
                        out.write(emu.readMemory(toAddr(PHASE), 2));
                    }
                }
                println("world " + world + " done");
            } finally {
                emu.dispose();
            }
        }
    }
}
