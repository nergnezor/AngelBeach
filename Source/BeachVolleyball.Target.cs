using UnrealBuildTool;
using System.Collections.Generic;

public class BeachVolleyballTarget : TargetRules
{
	public BeachVolleyballTarget(TargetInfo Target) : base(Target)
	{
		Type = TargetType.Game;
		DefaultBuildSettings = BuildSettingsVersion.V6;
		IncludeOrderVersion = EngineIncludeOrderVersion.Latest;
		ExtraModuleNames.Add("BeachVolleyball");
	}
}
