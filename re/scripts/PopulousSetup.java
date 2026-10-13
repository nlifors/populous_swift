// Prepares the raw DAD memory image for analysis: seeds disassembly at the entry
// points and at every C function prologue, then creates functions.
//@category Populous
import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.script.GhidraScript;
import java.io.File;
import java.math.BigInteger;
import java.nio.file.Files;

import ghidra.program.model.address.Address;
import ghidra.program.model.lang.Register;
import ghidra.program.model.listing.Function;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.symbol.SourceType;

public class PopulousSetup extends GhidraScript {
    static final long BASE = 0x5E7C4L;
    static final long ENTRY = 0x70F38L;
    // The Aztec C startup loads this into A4 once; all globals and the jump table
    // are addressed relative to it.
    static final long A4 = 0x7AB96L;
    static final long JUMP_TABLE = 0x72B9EL;
    static final long JUMP_TABLE_END = 0x72D9CL;

    @Override
    public void run() throws Exception {
        Memory mem = currentProgram.getMemory();
        Address start = toAddr(BASE);
        Address end = mem.getMaxAddress();

        Register a4 = currentProgram.getRegister("A4");
        currentProgram.getProgramContext().setValue(a4, start, end, BigInteger.valueOf(A4));

        seed(toAddr(BASE + 4), "dad_jump");
        seed(toAddr(ENTRY), "entry");

        // Far calls go through a table of JMP abs.l (4EF9) stubs reached as jsr (d16,A4).
        int stubs = 0;
        for (Address a = toAddr(JUMP_TABLE); a.getOffset() < JUMP_TABLE_END; a = a.add(6)) {
            if ((mem.getShort(a) & 0xFFFF) != 0x4EF9) continue;  // one slot holds data
            Address target = toAddr(mem.getInt(a.add(2)) & 0xFFFFFFFFL);
            new DisassembleCommand(target, null, true).applyTo(currentProgram, monitor);
            if (getFunctionAt(target) == null) createFunction(target, null);
            new DisassembleCommand(a, null, true).applyTo(currentProgram, monitor);
            if (getFunctionAt(a) == null) createFunction(a, null);
            stubs++;
        }
        println("jump table stubs: " + stubs);

        // Compiled C functions open with LINK A5,#-n (4E55 nnnn).
        int found = 0;
        for (Address a = start; a.compareTo(end) < 0; a = a.add(2)) {
            if ((mem.getShort(a) & 0xFFFF) != 0x4E55) continue;
            if (getInstructionContaining(a) != null && getFunctionAt(a) == null
                    && getInstructionAt(a) == null) continue;  // operand bytes of another instruction
            if (getFunctionAt(a) != null) continue;
            new DisassembleCommand(a, null, true).applyTo(currentProgram, monitor);
            if (getInstructionAt(a) != null && createFunction(a, null) != null) found++;
        }
        analyzeAll(currentProgram);
        applySymbols();
        println("prologue functions: " + found + ", total functions: "
                + currentProgram.getFunctionManager().getFunctionCount());
    }

    /** Applies re/symbols.txt: renames the function at each address, or labels the data. */
    private void applySymbols() throws Exception {
        File file = new File(getSourceFile().getParentFile().getParentFile().getAbsolutePath(), "symbols.txt");
        int applied = 0;
        for (String line : Files.readAllLines(file.toPath())) {
            String[] parts = line.split(";")[0].trim().split("\\s+");
            if (parts.length < 2 || parts[0].startsWith("#")) continue;
            Address a = toAddr(Long.parseLong(parts[0], 16));
            Function f = getFunctionAt(a);
            if (f != null) f.setName(parts[1], SourceType.USER_DEFINED);
            else createLabel(a, parts[1], true, SourceType.USER_DEFINED);
            applied++;
        }
        println("symbols applied: " + applied);
    }

    private void seed(Address a, String name) throws Exception {
        new DisassembleCommand(a, null, true).applyTo(currentProgram, monitor);
        Function f = createFunction(a, name);
        if (f == null) createLabel(a, name, true, SourceType.USER_DEFINED);
    }
}
