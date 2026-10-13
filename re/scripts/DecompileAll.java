// Decompiles every function to one C file and writes a function index:
// DecompileAll <out.c> <index.txt>
//@category Populous
import java.io.PrintWriter;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;

public class DecompileAll extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);
        try (PrintWriter c = new PrintWriter(args[0]); PrintWriter index = new PrintWriter(args[1])) {
            for (Function f : currentProgram.getFunctionManager().getFunctions(true)) {
                int callers = f.getCallingFunctions(monitor).size();
                int callees = f.getCalledFunctions(monitor).size();
                index.println(f.getEntryPoint() + " " + f.getBody().getNumAddresses() + " bytes, "
                        + callers + " callers, " + callees + " callees  " + f.getName());
                DecompileResults r = decompiler.decompileFunction(f, 60, monitor);
                c.println("// ---- " + f.getEntryPoint() + " " + f.getName());
                c.println(r.decompileCompleted() ? r.getDecompiledFunction().getC()
                        : "// decompile failed: " + r.getErrorMessage());
            }
        }
    }
}
