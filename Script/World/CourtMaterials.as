// Shipping-safe solid-colour materials for the procedural (sand/net/lines/posts/
// water) meshes.
//
// WHY THIS EXISTS — do not go back to /Engine/EngineDebugMaterials/*:
// Court.as and Environment.as used to load VertexColorMaterial and
// M_SimpleUnlitTranslucent from /Engine/EngineDebugMaterials/. Those render fine
// in the editor but NEVER applied in a packaged Android build: every procedural
// mesh came out with the engine's own fallback material instead. The give-away is
// visible in any device screenshot — the sand is the only mesh whose UVs span
// 0..1 (BuildSand), and it is the only one showing a checkerboard, because the
// fallback material's checker texture gets stretched across that UV range; every
// other mesh sets UV (0,0) on all verts, samples one texel, and comes out flat
// cream (posts, court lines, and the water plane that should be filling the
// horizon in blue). Force-cooking the debug materials via AlwaysCookMaps did not
// help — they are editor/debug content and are not usable material assets in a
// cooked Shipping build.
//
// BasicShapeMaterial is ordinary shipping content (it is the material the
// /Engine/BasicShapes meshes use, and SpawnFallbackBox in VolleyballPlayer.as
// already relies on it) and exposes a "Color" vector parameter, so a Dynamic
// Material Instance per section gives each mesh its colour.
//
// TRADE-OFFS this makes, both deliberate:
//  - It is LIT, where the debug materials were unlit. Sand/water now take the
//    sunset directional light, which is what you want anyway.
//  - It is OPAQUE and ignores vertex colour. So the sand's per-vertex crater/
//    footprint darkening (SandColors) and the net band's see-through alpha are
//    not rendered. The vertex colours are still written into the mesh sections,
//    so an authored vertex-colour material would bring the crater feedback back
//    for free. A genuinely see-through net needs either an authored translucent
//    material or net-shaped geometry (thin strips) instead of a solid quad.
//
// Note it is static-mesh-only: ProceduralMeshComponent is fine (it uses the same
// local vertex factory), but do NOT use it on the skeletal player mesh — that was
// tried and rejected at runtime with "missing bUsedWithSkeletalMesh=True!".
UMaterialInstanceDynamic ApplySolidColorMaterial(UMeshComponent Comp, int Section, FLinearColor Color)
{
	if (Comp == nullptr) return nullptr;

	UMaterialInterface Base = Cast<UMaterialInterface>(LoadObject(nullptr,
		"/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"));
	if (Base == nullptr) return nullptr;

	UMaterialInstanceDynamic MID = Comp.CreateDynamicMaterialInstance(Section, Base);
	if (MID != nullptr)
		MID.SetVectorParameterValue(n"Color", Color);
	return MID;
}
