import { describe, expect, test } from "bun:test";
import { resolveServer, registry, classifyTool } from "@/servers";

describe("server registry", () => {
  test("resolves gitnexus by prefix", () => {
    const spec = resolveServer("mcp__gitnexus__context");
    expect(spec?.serverPrefix).toBe("mcp__gitnexus__");
  });

  test("returns null for unregistered server", () => {
    expect(resolveServer("mcp__zenhub__listSprints")).toBeNull();
  });

  test("classifies decision-support tools", () => {
    expect(classifyTool("mcp__gitnexus__context")).toEqual({
      shortName: "context", toolClass: "decisionSupport",
    });
    expect(classifyTool("mcp__gitnexus__impact")).toEqual({
      shortName: "impact", toolClass: "decisionSupport",
    });
  });

  test("classifies exploratory tools", () => {
    expect(classifyTool("mcp__gitnexus__cypher")?.toolClass).toBe("exploratory");
    expect(classifyTool("mcp__gitnexus__query")?.toolClass).toBe("exploratory");
  });

  test("classifies side-effecting tools", () => {
    expect(classifyTool("mcp__gitnexus__rename")?.toolClass).toBe("sideEffecting");
  });

  test("classifies maintenance tools", () => {
    expect(classifyTool("mcp__gitnexus__analyze")?.toolClass).toBe("maintenance");
    expect(classifyTool("mcp__gitnexus__status")?.toolClass).toBe("maintenance");
    expect(classifyTool("mcp__gitnexus__clean")?.toolClass).toBe("maintenance");
  });

  test("classifies meta tools", () => {
    expect(classifyTool("mcp__gitnexus__list_repos")?.toolClass).toBe("meta");
  });

  test("registry exposes gitnexus only in v1", () => {
    expect([...registry.keys()]).toEqual(["mcp__gitnexus__"]);
  });
});
