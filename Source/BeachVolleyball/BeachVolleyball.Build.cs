using UnrealBuildTool;

public class BeachVolleyball : ModuleRules
{
	public BeachVolleyball(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;

		PublicDependencyModuleNames.AddRange(new string[]
		{
			"Core",
			"CoreUObject",
			"Engine",
			"InputCore",
			"ProceduralMeshComponent",
			"Niagara",
			"AngelscriptCode"
		});

		PrivateDependencyModuleNames.AddRange(new string[]
		{
			"Slate",
			"SlateCore"
		});

		if (Target.Platform == UnrealTargetPlatform.Android)
		{
			// Force-resolves an outdated transitive Play Billing AIDL dependency
			// that Play Console's pre-launch checks flag, even though this game
			// has no in-app purchases of its own. See the XML for details.
			AdditionalPropertiesForReceipt.Add("AndroidPlugin",
				System.IO.Path.Combine(ModuleDirectory, "Android", "AndroidBillingFix_UPL.xml"));
		}
	}
}
