using UnrealBuildTool;
using System.Collections.Generic;

public class BeachVolleyballEditorTarget : TargetRules
{
	public BeachVolleyballEditorTarget(TargetInfo Target) : base(Target)
	{
		Type = TargetType.Editor;
		DefaultBuildSettings = BuildSettingsVersion.Latest;
		IncludeOrderVersion = EngineIncludeOrderVersion.Latest;
		ExtraModuleNames.Add("BeachVolleyball");

		// No debugger is used against these builds — skip generating debug info
		// entirely rather than just skipping its (slow) post-link compression.
		DebugInfo = DebugInfoMode.None;
		bCompressDebugFile = false;
	}
}
