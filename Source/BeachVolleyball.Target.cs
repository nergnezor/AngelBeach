using UnrealBuildTool;
using System.Collections.Generic;

public class BeachVolleyballTarget : TargetRules
{
	public BeachVolleyballTarget(TargetInfo Target) : base(Target)
	{
		Type = TargetType.Game;
		DefaultBuildSettings = BuildSettingsVersion.Latest;
		IncludeOrderVersion = EngineIncludeOrderVersion.Latest;
		ExtraModuleNames.Add("BeachVolleyball");

		// See BeachVolleyballEditor.Target.cs — no debug info needed.
		DebugInfo = DebugInfoMode.None;
		bCompressDebugFile = false;
	}
}
