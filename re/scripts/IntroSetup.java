// Prepares the flattened intro program (the disk's `populous`) for analysis:
// seeds disassembly at its start and at every C function prologue.
// Argument: the A4 small-data base, once known (optional).
//@category Populous
import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.script.GhidraScript;
import java.math.BigInteger;

import ghidra.program.model.address.Address;
import ghidra.program.model.mem.Memory;

public class IntroSetup extends GhidraScript {
    @Override
    public void run() throws Exception {
        Memory mem = currentProgram.getMemory();
        Address start = mem.getMinAddress();
        Address end = mem.getMaxAddress();
        String[] args = getScriptArgs();
        if (args.length > 0) {
            currentProgram.getProgramContext().setValue(
                currentProgram.getRegister("A4"), start, end, BigInteger.valueOf(Long.decode(args[0])));
        }
        new DisassembleCommand(start, null, true).applyTo(currentProgram, monitor);
        createFunction(start, "start");
        int found = 0;
        for (Address a = start; a.compareTo(end) < 0; a = a.add(2)) {
            if ((mem.getShort(a) & 0xFFFF) != 0x4E55) continue;
            if (getFunctionAt(a) != null) continue;
            if (getInstructionContaining(a) != null && getInstructionAt(a) == null) continue;
            new DisassembleCommand(a, null, true).applyTo(currentProgram, monitor);
            if (getInstructionAt(a) != null && createFunction(a, null) != null) found++;
        }
        analyzeAll(currentProgram);
        println("prologue functions: " + found + ", total functions: "
                + currentProgram.getFunctionManager().getFunctionCount());
    }
}
