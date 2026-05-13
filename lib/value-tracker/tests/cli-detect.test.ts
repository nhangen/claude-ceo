import { describe, expect, test } from "bun:test";
import { detectCliInvocations } from "@/cli-detect";

describe("detectCliInvocations", () => {
  test("matches plain gitnexus subcommand", () => {
    const r = detectCliInvocations("gitnexus analyze");
    expect(r.length).toBe(1);
    expect(r[0]!.shortName).toBe("analyze");
    expect(r[0]!.toolClass).toBe("maintenance");
    expect(r[0]!.syntheticToolName).toBe("cli__gitnexus__analyze");
  });

  test("matches absolute path to gitnexus binary", () => {
    const r = detectCliInvocations('"/opt/homebrew/bin/gitnexus" analyze --force');
    expect(r.length).toBe(1);
    expect(r[0]!.shortName).toBe("analyze");
  });

  test("matches gitnexus inside a chained command", () => {
    const r = detectCliInvocations("cd /tmp && gitnexus status");
    expect(r.length).toBe(1);
    expect(r[0]!.shortName).toBe("status");
  });

  test("matches multiple invocations", () => {
    const r = detectCliInvocations("gitnexus analyze; gitnexus status");
    expect(r.length).toBe(2);
    expect(r.map((m) => m.shortName)).toEqual(["analyze", "status"]);
  });

  test("ignores comments referencing gitnexus", () => {
    const r = detectCliInvocations("# gitnexus analyze was run manually\nls");
    expect(r.length).toBe(0);
  });

  test("ignores echo / string payloads", () => {
    const r = detectCliInvocations('echo "reset gitnexus"');
    expect(r.length).toBe(0);
  });

  test("ignores unknown subcommand (not in any partition)", () => {
    const r = detectCliInvocations("gitnexus zzz-nonexistent");
    expect(r.length).toBe(0);
  });

  test("returns empty for empty input", () => {
    expect(detectCliInvocations("")).toEqual([]);
  });
});
