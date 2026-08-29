// Base player pawn - movement, jump, hit actions, skeletal (Manny) body.
//
// Animation architecture (no engine fork needed):
//   - This script drives an AnimInstance (UVolleyballAnimInstance) by writing
//     BlueprintReadWrite properties every frame (Speed, bIsInAir, hit state...).
//   - An Animation Blueprint reparented to UVolleyballAnimInstance reads those
//     properties in its AnimGraph and runs a BLENDED state machine + blendspaces
//     (idle/walk/run blend on Speed, jump/fall, and hit montages per EHitType).
//   - To add a new move later: add an EHitType value + set it here, then add a
//     state/clip in the Anim Blueprint. Logic stays in code; blending in the graph.

// Which volleyball contact the player is performing (read by the Anim Blueprint
// to pick bump / set / spike upper-body animation).
enum EHitType
{
	Hit_None,
	Hit_Bump,   // bagger / dig — forearm pass, arms low together
	Hit_Set,    // handpass — overhead two-hand set
	Hit_Spike,  // attack — overhead one-arm swing
	Hit_Block,  // block — both hands up at the net, reaching over toward the ball
	Hit_Serve,  // serve — left-hand toss, overhead right-arm strike (ServePhase drives it)
}

// Data carrier between gameplay code and the Animation Blueprint. Holds no
// animation logic itself — the AnimGraph (in the Anim BP) does the blending.
class UVolleyballAnimInstance : UAnimInstance
{
	// Locomotion
	UPROPERTY(BlueprintReadWrite) float Speed = 0.0f;        // horizontal speed (cm/s)
	UPROPERTY(BlueprintReadWrite) float ForwardSpeed = 0.0f; // signed, for fwd/bwd blend
	UPROPERTY(BlueprintReadWrite) float StrafeSpeed = 0.0f;  // signed, for left/right blend
	// Signed travel direction relative to the facing, in degrees (0 = running the
	// way we face, ±180 = backpedal, ±90 = strafe). The standard "Direction" input
	// for an orientation-aware locomotion blendspace in the ABP; holds its last
	// value while idle so the blend doesn't snap when speed crosses zero.
	UPROPERTY(BlueprintReadWrite) float MoveDirAngle = 0.0f;
	UPROPERTY(BlueprintReadWrite) bool  bIsMoving = false;

	// Air state
	UPROPERTY(BlueprintReadWrite) bool  bIsInAir = false;
	UPROPERTY(BlueprintReadWrite) float VerticalSpeed = 0.0f; // +up / -down, for jump/fall blend

	// Hit / contact state (drives which montage/state the Anim BP plays)
	UPROPERTY(BlueprintReadWrite) bool     bIsHitting = false;
	UPROPERTY(BlueprintReadWrite) EHitType HitType = EHitType::Hit_None;
	UPROPERTY(BlueprintReadWrite) float    HitAlpha = 0.0f;   // 0 -> 1 -> 0 swing envelope
	// Hit overlay clip picker: branch 0=bump, 1=set/spike; blend picks set (0) vs spike (1).
	UPROPERTY(BlueprintReadWrite) int      HitClipBranch = 0;
	UPROPERTY(BlueprintReadWrite) float    HitSetSpikeBlend = 0.0f;

	// --- Full Body IK effector targets (WORLD space) ----------------------
	// The Anim BP feeds these into a Full Body IK node. Code computes WHERE each
	// limb should be (relative to head/shoulders and the aim direction); the IK
	// node solves the joints so the hands/feet/hips land exactly there. This
	// replaces the old bone-space Modify Bone approach — no more guessing axes.
	//
	// IK is applied with weight IKAlpha (0 = pure animation, 1 = fully driven by
	// these targets), so arm gestures blend in/out smoothly over a contact.
	UPROPERTY(BlueprintReadWrite) float    IKAlpha = 0.0f;

	// Hands: where each palm should be, and which way it faces (for set/spike).
	UPROPERTY(BlueprintReadWrite) FVector  HandTargetR = FVector::ZeroVector;
	UPROPERTY(BlueprintReadWrite) FVector  HandTargetL = FVector::ZeroVector;
	UPROPERTY(BlueprintReadWrite) FRotator HandRotR = FRotator::ZeroRotator;
	UPROPERTY(BlueprintReadWrite) FRotator HandRotL = FRotator::ZeroRotator;

	// Elbow pole vectors: a world point the elbow points toward, so the IK picks
	// a natural elbow bend (forward for a set, down/out for a bump platform).
	UPROPERTY(BlueprintReadWrite) FVector  ElbowPoleR = FVector::ZeroVector;
	UPROPERTY(BlueprintReadWrite) FVector  ElbowPoleL = FVector::ZeroVector;

	// Lower body: hip height offset (negative = crouch) and dive hand plant.
	UPROPERTY(BlueprintReadWrite) float    CrouchAmount = 0.0f;  // 0..1, drives knee bend
	// WORLD-space pelvis target the Modify Bone node pulls the pelvis to. Feet
	// would sink into the ground with the pelvis were it not for FootTargetL/R
	// below re-planting them via Two Bone IK, which is what actually bends the
	// knees (the pelvis moves rigidly; the legs solve to keep the foot fixed).
	UPROPERTY(BlueprintReadWrite) FVector   PelvisTarget = FVector::ZeroVector;
	// WORLD-space foot targets for the leg Two Bone IK nodes: last frame's
	// solved foot position, read fresh each tick (see UpdateIKTargets) so the
	// foot holds still under a moving pelvis instead of sliding with it —
	// rotated by the actor's yaw change each frame so a fast turn carries the
	// foot around with the body instead of leaving it pinned in world space.
	UPROPERTY(BlueprintReadWrite) FVector   FootTargetL = FVector::ZeroVector;
	UPROPERTY(BlueprintReadWrite) FVector   FootTargetR = FVector::ZeroVector;
	// Weight for the LEG chain only (pelvis Modify Bone + both foot Two Bone IK
	// nodes) — the arms have their own IKAlpha above.
	//
	// THE LEG IK IS A CROUCH TOOL, NOT A GAIT. All it does is hold the feet
	// still while the pelvis sinks, so the knees have to fold. That is exactly
	// right for a receive, and exactly wrong while walking: the foot targets
	// track the actor (clamped to a stance radius around the hips), so a
	// walking player's legs get pinned under the body and never stride. The
	// base MM_Walk/MM_Run clips already contain a real gait; at alpha 0 the
	// legs are pure animation and that gait plays untouched. Fading in with
	// crouch depth means the IK only takes over when there is a crouch to
	// serve, which is the only time it has anything to contribute.
	UPROPERTY(BlueprintReadWrite) float    LegIKAlpha = 0.0f;
	UPROPERTY(BlueprintReadWrite) bool     bDiving = false;      // play dive montage

	// Head look-at: a WORLD-space point the head should turn toward (the ball), fed
	// into a "Look At" skeletal-control node on the head bone in the Anim BP. Always
	// active (LookAlpha) so players keep their eyes on the ball.
	UPROPERTY(BlueprintReadWrite) FVector  LookTarget = FVector::ZeroVector;
	UPROPERTY(BlueprintReadWrite) float    LookAlpha = 0.0f;     // 0..1 look-at weight
}
