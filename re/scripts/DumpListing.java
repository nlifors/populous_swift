// Writes a plain disassembly listing of an address range: DumpListing <start> <end> <file>
//@category Populous
import java.io.PrintWriter;

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;

public class DumpListing extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        Address a = toAddr(Long.decode(args[0]));
        Address end = toAddr(Long.decode(args[1]));
        try (PrintWriter out = new PrintWriter(args[2])) {
            Instruction ins = getInstructionAt(a);
            if (ins == null) ins = getInstructionAfter(a);
            while (ins != null && ins.getAddress().compareTo(end) < 0) {
                Function f = getFunctionAt(ins.getAddress());
                if (f != null) out.println("\n" + f.getName() + ":");
                out.println(ins.getAddress() + "  " + ins);
                ins = ins.getNext();
            }
        }
    }
}
