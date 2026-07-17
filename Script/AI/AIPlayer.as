// AI player - volleyball state machine: Receive -> Set -> Attack with proper
// roles, height-aware contacts, and team coordination (no flip-flopping).

enum EPlayerRole { Role_Back, Role_Front }

class AAIPlayer : AVolleyballPlayer
{
	UPROPERTY(BlueprintReadWrite) float Difficulty = 0.75f;
	UPROPERTY(BlueprintReadWrite) EPlayerRole Role = EPlayerRole::Role_Back;
	UPROPERTY() ABall Ball;
	UPROPERTY() AAIPlayer Teammate;  // the other player on this team

	float ReactionDelay = 0.0f;
	float ReactionTimer = 0.0f;

	// True if I made my team's most recent contact — so my teammate takes the
	// next touch (digger != setter != attacker), preventing one player from
	// making all three touches and committing a fourth-touch fault.
	bool bIMadeLastTouch = false;

	// --- Contact-height windows (relative to ball Z) ---
	// Dig:   ball low, near waist/chest      -> bump it up
	// Set:   ball at chest/head height       -> soft high arc
	// Spike: ball above head while airborne  -> drive it down
	const float DigMaxZ   = 130.0f;   // ball below this = dig
	const float SetMinZ   = 110.0f;
	const float SetMaxZ   = 220.0f;
	const float SpikeMinZ = 200.0f;   // need a jump to reach

	void Setup(ETeam Team, EPlayerRole InRole, float InDifficulty,
		ABall InBall, ASandFX InSand, ACourt InCourt, ABeachVolleyballGameMode InGM)
	{
		TeamSide = Team;
		Role = InRole;
		Difficulty = InDifficulty;
		Ball = InBall;
		Sand = InSand;
		Court = InCourt;
		GM = InGM;
		MoveSpeed = 420.0f + Difficulty * 220.0f;
		ReactionDelay = Math::Lerp(0.35f, 0.04f, Difficulty);

		CourtMinY = -450.0f;
		CourtMaxY = 450.0f;
		if (Team == ETeam::Team_A) { CourtMinX = -900.0f; CourtMaxX = -5.0f; }
		else                       { CourtMinX =    5.0f; CourtMaxX = 900.0f; }
	}

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		InitPlayer();
		CourtMinX = -900.0f; CourtMaxX = -5.0f;
		CourtMinY = -450.0f; CourtMaxY = 450.0f;
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		UpdatePlayer(DeltaTime);
		if (Ball == nullptr) FindBall();

		// Split step runs at full frame rate (not gated by ReactionDelay) so the
		// dip lands exactly on the opponent's contact.
		UpdateSplitStep(DeltaTime);

		// Dead ball (between points / before serve): WALK to my ready position so
		// the next rally starts from a proper formation — nobody sprints between
		// points. Also clear touch ownership: it must NOT leak into the next
		// rally, or last rally's final toucher refuses the serve receive and the
		// wrong (far) player has to scramble for it.
		// A serve in progress owns the player until the follow-through completes —
		// note this is checked BEFORE the dead-ball branch because the ball goes
		// live at the strike (phase 0.78) while the gesture runs to 1.0.
		if (bServing)
		{
			RunServeSequence(DeltaTime);
			return;
		}

		if (Ball == nullptr || !Ball.bInPlay)
		{
			bIMadeLastTouch = false;
			MoveToHold(ReadyPosition(), DeltaTime, 0.5f);
			PreFaceForServe();
			return;
		}

		ReactionTimer += DeltaTime;
		if (ReactionTimer < ReactionDelay) return;
		ReactionTimer = 0.0f;

		UpdateAI(DeltaTime);
	}

	// Formation spot to occupy while the ball is dead, depending on whether our
	// team is serving or receiving:
	//  - RECEIVING team: both players spread across mid-court, one per Y half, ready
	//    to dig the serve.
	//  - SERVING team: the server (back) stands behind the baseline; the non-server
	//    (front) waits up at the net.
	// By convention the Back-role player is the server.
	protected FVector ReadyPosition() const
	{
		float Sign = MySign();
		float Z = FloorZ + PlayerHeight;

		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		bool bWeServe = (GS != nullptr && GS.ServingTeam == TeamSide);

		if (bWeServe)
		{
			if (Role == EPlayerRole::Role_Back)
				return FVector(Sign * 820.0f, 0.0f, Z);     // server behind the baseline
			else
				return FVector(Sign * 130.0f, 0.0f, Z);     // partner up at the net
		}

		// Receiving: spread to mid-court, one on each Y half.
		float Y = (Role == EPlayerRole::Role_Front) ? -200.0f : 200.0f;
		return FVector(Sign * 450.0f, Y, Z);                 // mid-depth, half each
	}

	// ---------------------------------------------------------------
	// Serve — a real motion, not a ball teleport: the server walks to the
	// baseline, tosses with the LEFT hand (the ball rides the hand up), draws the
	// right arm back, strikes overhead and follows through. The ball launches at
	// the strike moment, from the strike point. GameMode starts this via
	// BeginServe(); RunServeSequence ticks it while the ball is dead.
	// ---------------------------------------------------------------
	protected bool bServing = false;
	private float ServeSeqTimer = 0.0f;
	private bool bServeLaunched = false;
	private FVector PendingServeVel;
	// Toss free-flight state: the ball is RELEASED from the left hand and flies
	// ballistically (computed here — it isn't in play yet) until the strike.
	private bool bTossReleased = false;
	private FVector TossVel;
	private FVector TossReleasePos;
	private float TossReleaseTime = 0.0f;
	const float TossReleasePhase = 0.55f;   // left hand lets go
	const float ServeStrikePhase = 0.78f;   // right hand meets the ball
	// Unhurried, like a real serve ritual (~2s toss->strike). Also required: the
	// Anim BP's FBIK effectors interpolate toward their targets with limited
	// speed, so a faster choreography outruns the arms (the toss never rose when
	// this was 1.15s — the hand lagged half a metre behind its target).
	const float ServeSeqDuration = 1.9f;

	void BeginServe(FVector ServeVel)
	{
		bServing = true;
		bServeLaunched = false;
		bTossReleased = false;
		ServeSeqTimer = 0.0f;
		PendingServeVel = ServeVel;
	}

	// While waiting at the baseline as the upcoming server, face the court — the
	// serve ritual must not start with a 180° pirouette (the toss hand swings
	// around with the turning body and the carry starts at the hip).
	protected void PreFaceForServe()
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr || GS.ServingTeam != TeamSide || Role != EPlayerRole::Role_Back)
			return;
		FacingDir = FVector(-MySign(), 0, 0);
		bHasFacing = true;
	}

	protected void RunServeSequence(float Dt)
	{
		if (Ball == nullptr) { bServing = false; ServePhase = 0.0f; return; }

		ServeSeqTimer += Dt;
		ServePhase = Math::Clamp(ServeSeqTimer / ServeSeqDuration, 0.0f, 1.0f);

		// Face the opponent court; the IK choreography runs off ServePhase.
		FacingDir = FVector(-MySign(), 0, 0);
		bHasFacing = true;
		Reach(EHitType::Hit_Serve);
		MovePlayer(FVector2D::ZeroVector);

		// A REAL toss: the ball rides the left hand up, is RELEASED into a short
		// free flight (up and back down to release height — a precise beach
		// toss), and launches only when the right hand whips through at the
		// strike phase. Launching straight off the glued hand made the ball
		// simply fly away from the left hand with no toss and no visible strike.
		if (!bServeLaunched && Mesh != nullptr)
		{
			if (ServePhase < TossReleasePhase)
			{
				FVector Carry = Mesh.GetBoneTransform(n"hand_l").Location + FVector(0, 0, 16);
				Ball.Position = Carry;
				Ball.BallVel = FVector::ZeroVector;
				Ball.SetActorLocation(Carry);
			}
			else if (ServePhase < ServeStrikePhase)
			{
				if (!bTossReleased)
				{
					bTossReleased = true;
					// Symmetric flight: peaks mid-window and returns to release
					// height exactly at the strike, so the ball is back where the
					// choreographed strike hand (StrikeR ≈ toss apex) meets it.
					TossReleasePos = Ball.Position;
					TossReleaseTime = ServeSeqTimer;
					float TFree = (ServeStrikePhase - TossReleasePhase) * ServeSeqDuration;
					TossVel = FVector(0, 0, 490.0f * TFree);
				}
				// CLOSED-FORM flight, not per-frame Euler: HighResShot hitches
				// (0.3-0.5s frames during filming) fed giant steps into the Euler
				// toss and slammed the ball to waist height before the strike —
				// the analytic parabola is immune to frame time.
				float T = ServeSeqTimer - TossReleaseTime;
				FVector TossPos = TossReleasePos
					+ FVector(0, 0, TossVel.Z * T - 490.0f * T * T);
				Ball.Position = TossPos;
				Ball.SetActorLocation(TossPos);
			}
			else
			{
				// Strike: launch from wherever the toss actually is. The contact
				// cooldown stops the ball bouncing off the server's own raised
				// hands on its first in-play frame (it starts near the strike hand).
				bServeLaunched = true;
				Ball.Launch(Ball.Position, PendingServeVel);
				Ball.PlayerHitCooldown = 0.35f;
				if (GM != nullptr)
					GM.OnServeLaunched();
			}
		}

		if (ServePhase >= 1.0f)
		{
			bServing = false;
			ServePhase = 0.0f;
		}
	}

	// ---------------------------------------------------------------
	// Main decision loop (protected so AHumanPlayer can reuse it as its
	// AI fallback when no gamepad input is active)
	// ---------------------------------------------------------------
	protected void UpdateAI(float DeltaTime)
	{
		// Ball is on the opponent's side: play DEFENSE and clear our touch-ownership
		// so the next receive starts fresh.
		if (!IsBallComingToMySide())
		{
			bIMadeLastTouch = false;
			PlayDefense(DeltaTime);
			return;
		}

		int Touches = TeamTouches();          // how many times WE have touched it
		FVector Landing = Ball.PredictLanding();

		// Decide my job for this contact based on touch count + role
		if (AmIHitter(Landing))
		{
			if (bDebugAI) Log(DebugTag() + " HITTER t=" + Touches + " ballZ=" + int(Ball.Position.Z) + " grounded=" + bIsGrounded);
			PlayHitter(Touches, DeltaTime);
		}
		else
		{
			if (bDebugAI) Log(DebugTag() + " SUPPORT t=" + Touches);
			PlaySupport(Landing, DeltaTime);
		}
	}

	// Temporary diagnostics — set true on ONE player from GameMode to inspect.
	bool bDebugAI = false;
	private FString DebugTag() const
	{
		FString T = (TeamSide == ETeam::Team_A) ? "A" : "B";
		FString R = (Role == EPlayerRole::Role_Front) ? "Front" : "Back";
		return T + "/" + R;
	}

	// ---------------------------------------------------------------
	// Role assignment — deterministic so the two players never swap
	// mid-rally and end up chasing the same ball.
	// ---------------------------------------------------------------
	private bool AmIHitter(FVector Landing) const
	{
		if (Teammate == nullptr) return true;

		// I never take two contacts in a row — if I made the last touch, it's
		// my teammate's turn now. This guarantees digger != setter != attacker.
		if (bIMadeLastTouch) return false;
		if (Teammate.bIMadeLastTouch) return true;

		// Fresh ball coming over (no team touches yet): closest player digs,
		// with the back player favored for deep balls (typical serve receive).
		float MyDist    = (GetActorLocation() - Landing).Size2D();
		float TheirDist = (Teammate.GetActorLocation() - Landing).Size2D();

		bool bDeep = IsDeep(Landing.X);
		if (bDeep && Role == EPlayerRole::Role_Back)  return true;
		if (bDeep && Role == EPlayerRole::Role_Front) return false;

		return MyDist <= TheirDist;
	}

	// ---------------------------------------------------------------
	// I am the player who will contact the ball this touch
	// ---------------------------------------------------------------
	private void PlayHitter(int Touches, float DeltaTime)
	{
		if (Touches >= 2)
		{
			// ATTACK: get under a high ball, jump, and spike at the peak
			ApproachForSpike(DeltaTime);
			return;
		}

		// Decide our intended contact type. A fingerpass (set) is legal only if we
		// can get UNDER the ball with our forehead in time. We judge this against the
		// spot where the ball will be at forehead height (where we're heading) and
		// whether we can plausibly reach that spot before the ball arrives — not the
		// ball's current position, which is still mid-flight when we decide.
		EHitType Intend;
		if (Touches == 0)
		{
			Intend = EHitType::Hit_Bump;   // first touch (receive) is always a dig
		}
		else
		{
			float ForeheadZ = GetActorLocation().Z + PlayerHeight * 0.9f;
			// Where the ball will be when it drops to forehead height.
			FVector SetSpot = PredictBallAtHeight(ForeheadZ);
			float DistToSetSpot = (GetActorLocation() - FVector(SetSpot.X, SetSpot.Y, 0)).Size2D();
			// Will the ball actually descend to forehead height (i.e. is it high
			// enough to set), and can we get under that spot in time?
			bool bBallSettable = SetSpot.Z >= ForeheadZ - 20.0f;
			bool bCanGetUnder = DistToSetSpot < UnderBallRadius;
			Intend = (bBallSettable && bCanGetUnder) ? EHitType::Hit_Set : EHitType::Hit_Bump;
		}

		// Aim where we want to send it (sets the bounce direction for contact).
		if (Intend == EHitType::Hit_Bump) DoDig();
		else                              DoSet();

		// Desperate ball: it will drop to play height before we can run there —
		// launch a dive at it instead of jogging hopelessly and watching it land.
		if (CanDive())
		{
			FVector DiveSpot;
			float TauC = PredictBallTimeToHeight(ContactHeight(), DiveSpot);
			if (TauC > 0.0f)
			{
				float DDist = (GetActorLocation() - FVector(DiveSpot.X, DiveSpot.Y, GetActorLocation().Z)).Size2D();
				float TMe = DDist / MoveSpeed + 0.12f;   // includes first-step lag
				if (TMe > TauC + 0.05f && TauC < 0.8f && DDist > 130.0f && DDist < 400.0f)
				{
					StartDive(DiveSpot - GetActorLocation());
					if (bDebugAI) Log(DebugTag() + " DIVE dist=" + int(DDist) + " tau=" + int(TauC * 100));
				}
			}
		}
		if (IsDiving())
		{
			// The dive owns movement and facing; just keep the platform out.
			Reach(EHitType::Hit_Bump);
			return;
		}

		// Stand where the ball will be when it drops to PLAY height — MINUS a
		// standoff along the ball's flight, so the contact happens IN FRONT of
		// the chest where the platform/cup is, never on top of the head. This is
		// the core of physical ball control: body behind the ball, facing it,
		// meeting it in front.
		FVector PlaySpot;
		float TauC = PredictBallTimeToHeight(ContactHeightFor(Intend), PlaySpot);
		// Standoff along the flight CHORD (ball -> predicted spot): stable, unlike
		// the live velocity which swings during the rally and made the goal churn.
		// Only applied while the ball is actually inbound toward the spot.
		FVector Chord = FVector(PlaySpot.X - Ball.Position.X, PlaySpot.Y - Ball.Position.Y, 0);
		FVector Vel2D = FVector(Ball.BallVel.X, Ball.BallVel.Y, 0);
		float Standoff = (Intend == EHitType::Hit_Set) ? 10.0f : 35.0f;
		FVector Back = (Chord.SizeSquared() > 400.0f && Vel2D.DotProduct(Chord) > 0.0f)
			? Chord.GetSafeNormal()
			: FVector::ZeroVector;                     // vertical drop/outbound: no standoff
		FVector Goal = ClampToCourt(FVector(PlaySpot.X, PlaySpot.Y, 0) + Back * Standoff);
		float DistToGoal = (GetActorLocation() - Goal).Size2D();

		// Move with URGENCY MATCHED TO TIME: hustle only as fast as the ball
		// demands. A pro with three seconds of hang time walks under the ball; one
		// with under a second SPRINTS, no arithmetic. The reserve accounts for
		// reaction lag + acceleration, which the naive dist/time math ignored —
		// that starved serve receives and they dove hopelessly at landing balls.
		float SpeedCap = 1.0f;
		if (TauC > 0.9f)
		{
			float NeedSpeed = DistToGoal / (TauC - 0.35f);    // reserve: react + accelerate
			SpeedCap = Math::Clamp((NeedSpeed / MoveSpeed) * 1.25f, 0.5f, 1.0f);
		}

		if (DistToGoal > PlantRadius)
			MoveToward2D(Goal, DeltaTime, false, SpeedCap);
		else
		{
			MovePlayer(FVector2D::ZeroVector);
			// Planted and waiting: LOW base. A bagger wants the centre of mass
			// down (legs set the height; the arms just hold their slope).
			RequestCrouch(Intend == EHitType::Hit_Bump ? 0.45f : 0.25f);
		}

		// The HITTER always faces the ball. Conditional facing (travel vs ball)
		// oscillated at the gate boundary every AI tick, whipping the chest-
		// anchored IK targets around so the arms never converged — hands ended up
		// 80-115cm from their targets at contact. Travel-facing is only for
		// players who are NOT about to play the ball (support/defense).
		FaceBall();

		// Wind up when MY contact is imminent in TIME — no distance condition. I'm
		// the designated hitter: if I'm still moving when the ball is close in
		// time, the arms must extend WHILE closing (that reach is what saves a
		// late receive — the platform intercepts even when the body is a step
		// short). 1.15s lead because the ABP's FBIK effectors chase their targets
		// with limited speed: arms started at 0.9s were still converging at
		// contact (handVsTarget 50-110cm in the miss autopsies).
		if (TauC >= 0.0f && TauC < 1.15f)
			Reach(Intend);
	}

	// Distance at which we START preparing the swing/arms. Generous so the wind-up
	// has time to develop before the ball gets here.
	const float PrepareDistance = 280.0f;

	// How close (cm) we must be to the landing spot before we plant and reach.
	// Tight so we actually arrive UNDER the ball rather than stopping short — the
	// main reason passes were poor was planting half a metre off the contact spot.
	const float PlantRadius = 40.0f;

	// How close (horizontally, cm) we must be under the ball to use a fingerpass
	// (set). Beyond this we're not under it in time and must bagger instead. Widened
	// so that whenever we've actually run under a high ball we fingerpass it (better
	// height/control) instead of defaulting to a flat bagger.
	const float UnderBallRadius = 100.0f;

	// The world Z at which we want to meet the ball — stroke-aware, at the point
	// THIS body controls best. True hip-height (85cm) contact was tried and the
	// FBIK could not converge to knee-low targets in the ~0.2s the ball spends
	// there — waist height (~112cm) is where the hands arrive fastest from ready,
	// which IS the physical optimum for this rig. Sets are taken above the brow.
	private float ContactHeightFor(EHitType Intend) const
	{
		if (Intend == EHitType::Hit_Set)
			return GetActorLocation().Z + PlayerHeight * 0.9f;
		return FloorZ + 112.0f;
	}

	// Back-compat for callers that don't know the stroke yet (dig by default).
	private float ContactHeight() const
	{
		return ContactHeightFor(EHitType::Hit_Bump);
	}

	// Simulate the ball forward and return its (X,Y,Z) when it next descends to the
	// given height. If it never reaches that height (already below / rising away),
	// fall back to the ground landing prediction.
	private FVector PredictBallAtHeight(float TargetZ) const
	{
		FVector Pos;
		PredictBallTimeToHeight(TargetZ, Pos);
		return Pos;
	}

	// Same simulation, but also returns WHEN (seconds from now) the ball next
	// descends through TargetZ — the number that lets us TIME a jump or a dive
	// instead of just aiming at a spot. Returns -1 if the ball never crosses that
	// height before landing (OutPos then holds the ground landing prediction).
	protected float PredictBallTimeToHeight(float TargetZ, FVector& OutPos) const
	{
		FVector P = Ball.Position;
		FVector V = Ball.BallVel;
		const float G = -980.0f;
		const float Dt = 0.02f;
		float T = 0.0f;
		while (T < 3.0f)
		{
			V.Z += G * Dt;
			FVector Next = P + V * Dt;
			// Detect a downward crossing of TargetZ between P and Next.
			if (P.Z >= TargetZ && Next.Z <= TargetZ && V.Z < 0.0f)
			{
				OutPos = Next;
				return T + Dt;
			}
			P = Next;
			T += Dt;
			if (P.Z <= 0.0f) break;
		}
		OutPos = Ball.PredictLanding();
		return -1.0f;
	}

	private void FaceBall()
	{
		// Request facing via the single rotation authority (UpdatePlayer lerps to it)
		// rather than snapping the rotation here — snapping fought the travel-facing
		// and caused jerky spinning, especially mid-jump.
		FVector To = Ball.Position - GetActorLocation();
		To.Z = 0;
		if (To.SizeSquared() > 1.0f)
		{
			FacingDir = To.GetSafeNormal();
			bHasFacing = true;
		}
	}

	// ---------------------------------------------------------------
	// I am NOT contacting this touch — get to the right support spot.
	// Crucially, anticipate MY upcoming touch in the three-touch rhythm:
	//  - after our receive (1 touch), I'll be the setter -> go to the setter zone
	//  - after our set (2 touches), I'll be the attacker -> go to the net to spike
	// so I'm already in position when the ball comes to me.
	// ---------------------------------------------------------------
	private void PlaySupport(FVector Landing, float DeltaTime)
	{
		int Touches = TeamTouches();
		float Sign = MySign();
		FVector Target;

		if (Touches == 1)
		{
			// Our receive is up; I set next. Get UNDER where the ball will actually
			// drop to forehead height as early as possible — not just the nominal
			// setter zone — so I'm planted under it in time to play a clean, high
			// fingerpass instead of arriving late and scrambling a bagger. Fall back
			// to the setter zone only before the receive has been hit (no useful
			// prediction yet).
			float ForeheadZ = GetActorLocation().Z + PlayerHeight * 0.9f;
			FVector SetSpot = PredictBallAtHeight(ForeheadZ);
			bool bUsefulPredict = SetSpot.Z >= ForeheadZ - 20.0f
				&& (TeamSide == ETeam::Team_A ? SetSpot.X <= 0.0f : SetSpot.X >= 0.0f);
			Target = bUsefulPredict
				? FVector(SetSpot.X, SetSpot.Y, FloorZ + PlayerHeight)
				: SetterZone();
		}
		else if (Touches == 2)
		{
			// Our set is up and my TEAMMATE attacks (I just set it — AmIHitter
			// never gives me two touches in a row). COVER the attack: drop to
			// mid-court behind the hitter for the block rebound. Running to the
			// net with them just crowded the attack lane with two bodies.
			Target = FVector(Sign * 480.0f, Landing.Y * 0.5f, FloorZ + PlayerHeight);
		}
		else
		{
			Target = SupportPos(Landing);
		}

		// The setter (Touches==1) is tracking a moving target — the spot the ball is
		// dropping to — so chase it directly and arrive under it early. Holding with
		// hysteresis there would leave us planted a half-metre off the descending ball.
		// Support/cover roles still HOLD their spot to avoid constant shuffling.
		if (Touches == 1)
		{
			// The upcoming setter is the NEXT hitter — same rule: always face the
			// ball so the cup/platform targets stay stable while closing in.
			MoveToward2D(ClampToCourt(Target), DeltaTime);
			FaceBall();
			return;
		}

		// Always keep at least MinSeparation from my teammate so our team holds two
		// distinct options: whoever gets the ball can attack into open space OR pass
		// to the well-separated partner. Push my target away from the teammate along
		// the line between us until we're far enough apart.
		Target = SpreadFromTeammate(Target);

		// Take the spot and HOLD it (no constant shuffling), facing the play in a
		// ready stance once there. Repositioning is a jog FACING THE TRAVEL —
		// there's no ball to chase, just ground to cover.
		Target = ClampToCourt(Target);
		MoveToHold(Target, DeltaTime, 0.75f);
		RequestCrouch(0.18f);
		if ((Target - GetActorLocation()).Size2D() < 150.0f)
			FaceAttacker();
	}

	// Turn to face whichever teammate/opponent is about to attack (or the ball), so
	// we're oriented into the play while standing still.
	private void FaceAttacker()
	{
		// Same single-authority facing request (smooth lerp in UpdatePlayer).
		FVector Look = Ball.Position - GetActorLocation();
		Look.Z = 0;
		if (Look.SizeSquared() > 1.0f)
		{
			FacingDir = Look.GetSafeNormal();
			bHasFacing = true;
		}
	}

	// Minimum desired distance between teammates: about half the court width, so an
	// attacker always has a spike option AND a clearly separated pass option.
	const float MinSeparation = 450.0f;   // ~half of the 900cm-wide court

	// Nudge a desired position away from my teammate so we end up at least
	// MinSeparation apart. Keeps the original spot when we're already spread.
	private FVector SpreadFromTeammate(FVector Desired) const
	{
		if (Teammate == nullptr) return Desired;
		FVector Mate = Teammate.GetActorLocation();
		FVector Away = FVector(Desired.X - Mate.X, Desired.Y - Mate.Y, 0);
		float Dist = Away.Size2D();
		if (Dist >= MinSeparation) return Desired;          // already far enough

		// Too close: move out to MinSeparation along the away direction. If we're
		// almost on top of each other, push along Y (down the court) by default.
		FVector Dir = (Dist > 1.0f) ? Away.GetSafeNormal2D() : FVector(0, 1, 0);
		FVector Spread = Mate + Dir * MinSeparation;
		return FVector(Spread.X, Spread.Y, Desired.Z);
	}

	// ---------------------------------------------------------------
	// Spike approach — world-class shape: wait loaded at an approach start point
	// BEHIND the predicted strike spot, then a committed sprint through the
	// plant, jumping so the apex coincides with the ball arriving at strike
	// height. Momentum now carries through the jump (no air steering), which is
	// exactly how a real approach converts run speed into attack reach.
	// ---------------------------------------------------------------
	// Contact height for the jump attack: hands top out ~424cm at the jump apex
	// (chest ~329 + arm ~95), so we strike where the DESCENDING ball is slow and
	// still inside that envelope. 380 was tuned for floatier sets; with the
	// faster ones it put the ball 75cm above the hands at apex.
	const float SpikeStrikeZ = 410.0f;
	const float ApproachBack = 200.0f;  // run-up starts this far behind the plant

	private void ApproachForSpike(float DeltaTime)
	{
		float TimeToApex = JumpVelocity / 980.0f;   // ≈ 0.61s

		FVector Strike;
		float Tau = PredictBallTimeToHeight(SpikeStrikeZ, Strike);

		if (Tau < 0.0f)
		{
			// The set never gets to strike height — no jump attack available. Get
			// under where it drops to play height and hit it over instead.
			FVector PlaySpot = PredictBallAtHeight(ContactHeight());
			MoveToward2D(ClampToCourt(FVector(PlaySpot.X, PlaySpot.Y, 0)), DeltaTime);
			FaceBall();
			DoSpike();   // still aim into the opponent court
			if ((GetActorLocation() - Ball.Position).Size() < PrepareDistance)
				Reach(EHitType::Hit_Bump);
			return;
		}

		// Plant just our-side of the strike point so contact happens in front of
		// the hitting shoulder, not on top of the head.
		FVector Plant = ClampToCourt(FVector(Strike.X + MySign() * 35.0f, Strike.Y, 0));
		float DistToPlant = (GetActorLocation() - Plant).Size2D();
		float SprintTime = DistToPlant / MoveSpeed + 0.15f;   // + first-step lag

		bool bGo = false;
		if (bIsGrounded)
		{
			if (Tau > SprintTime + TimeToApex + 0.25f)
			{
				// Early: wait loaded at the approach start point behind the plant —
				// coiled stance, eyes on the ball, arms QUIET until the run starts.
				FVector Start = ClampToCourt(Plant + FVector(MySign() * ApproachBack, 0, 0));
				MoveToHold(Start, DeltaTime, 0.8f);
				RequestCrouch(0.25f);
				FaceBall();
			}
			else
			{
				bGo = true;
				// GO: committed sprint TO the plant point, shoulders OPEN —
				// a right-handed hitter runs in with the left shoulder leading and
				// the chest turned ~22° off the ball line, loading the torso. The
				// body squares up through the jump (FaceBall in the air + the slow
				// rotation lerp gives exactly that uncoiling). Sprint only OUTSIDE
				// the jump radius: full-speed drive through the plant made the
				// hitter overshoot and violently shuttle back and forth over it
				// while waiting for the jump window.
				MoveToward2D(Plant, DeltaTime, DistToPlant > 90.0f);
				FVector To = Ball.Position - GetActorLocation();
				To.Z = 0;
				if (To.SizeSquared() > 1.0f)
				{
					const float OpenRad = -22.0f * PI / 180.0f;
					float C = Math::Cos(OpenRad);
					float Sn = Math::Sin(OpenRad);
					FVector N = To.GetSafeNormal();
					FacingDir = FVector(N.X * C - N.Y * Sn, N.X * Sn + N.Y * C, 0);
					bHasFacing = true;
				}
				// Leave the ground one apex-time before the ball reaches the strike
				// height; stop driving so the jump converts momentum, not input.
				// MARGIN BIAS MATTERS: an EARLY jump tops out while the ball is
				// still above the hands (a guaranteed whiff — stats2: 13 jumps, 0
				// contacts at +0.18); a LATE jump meets the ball a touch lower but
				// still inside the envelope. Keep the margin tiny so AI tick
				// jitter lands on the late (reachable) side.
				if (DistToPlant < 90.0f && Tau <= TimeToApex + 0.04f)
				{
					MovePlayer(FVector2D::ZeroVector);
					// PLANT: the penultimate-step brake every real approach has.
					// Keeping full sprint momentum carried the hitter 3-4m PAST
					// the strike point in the air (bodyHoriz 300-500 in the whiff
					// autopsies) — the jump must convert run into HEIGHT. The 25%
					// residue is the natural forward drift that closes the last
					// ~90cm to the ball during the ascent.
					PlayerVelocity.X *= 0.25f;
					PlayerVelocity.Y *= 0.25f;
					Jump();
					if (bDebugAI) Log(DebugTag() + " SPIKE JUMP tau=" + int(Tau * 100) + " dist=" + int(DistToPlant));
				}
			}
		}
		else
		{
			// Airborne: no swimming; momentum carries us to the strike. Square the
			// shoulders to the ball — uncoiling from the open approach stance.
			MovePlayer(FVector2D::ZeroVector);
			FaceBall();
		}

		// Wind up ONLY during the committed run and the jump itself — an attacker
		// standing at the approach start with arms already loaded read as random
		// arm-raising. The IK develops backswing -> cocked -> strike as the ball
		// drops toward the strike point. The reach is asked only while the ball
		// is ABOVE the chest: once a whiffed ball has fallen past it, stop
		// asking for the spike so AutoReach can flip to a desperation bump —
		// arms stuck in spike pose can never play the low rescue.
		if ((bGo || !bIsGrounded) && Ball.Position.Z > GetActorLocation().Z + 40.0f)
		{
			DoSpike();
			Reach(EHitType::Hit_Spike);
		}
	}

	// ---------------------------------------------------------------
	// Contacts — the ball now physically bounces off the player. These set the
	// AIM target so OnBallContact (on the base player) knows where to send it.
	// ---------------------------------------------------------------
	// The shared setter target: where a receive lands and where the setter goes.
	// Central in Y (0) so the second-ball attack can go either direction, and a bit
	// off the net (so the set has room) — a high, central, attackable second ball.
	private FVector SetterZone() const
	{
		return FVector(MySign() * SetterZoneX, 0.0f, FloorZ + PlayerHeight);
	}
	const float SetterZoneX = 280.0f;

	private void DoDig()
	{
		// Receive: pop the ball UP and OVER THE MIDDLE to the setter zone. The
		// contact is ballistic (BallisticVelocity in OnBallContact): the aim point
		// is where the arc comes DOWN — chest height in the setter zone, centre
		// court (Y=0) so the 2nd-ball attack can go either direction.
		FVector Zone = SetterZone();
		AimAt(FVector(Zone.X, Zone.Y, 150.0f));
	}

	private void DoSet()
	{
		// Set: a HIGH float the attacker can take a full jump attack on. Ballistic
		// contact: aim at the attack spot, arc apex ~4m up — the ball crosses
		// strike height (~SpikeStrikeZ) descending right over the plant point.
		//
		// SET TO YOUR PARTNER: the next hitter is always the player who did NOT
		// just touch (the roles guarantee it) — usually the RECEIVER, still deep
		// after the pass. Aiming at "the front player's Y" put the ball where the
		// attacker wasn't and the third touch never happened (the ball dropped
		// untouched on the attack spot). Aim at the partner's actual Y so their
		// approach is a straight run-in.
		float Sign = MySign();
		float SetX = Sign * 250.0f;
		float SetY = (Teammate != nullptr)
			? Math::Clamp(Teammate.GetActorLocation().Y, CourtMinY + 120.0f, CourtMaxY - 120.0f)
			: Ball.Position.Y * 0.4f;
		AimAt(FVector(SetX, SetY, 170.0f));
	}

	private void DoSpike()
	{
		// Aim down into the opponent's open court; OnBallContact forces the angle.
		AimAt(PickAttackTarget());
	}

	// Tell the base player where to send the ball on the next physical contact.
	private void AimAt(FVector WorldTarget)
	{
		DesiredAim = WorldTarget;
		bHasAim = true;
	}

	// Aim for the opponent's open court, away from their players
	private FVector PickAttackTarget() const
	{
		float OppSign = -MySign();
		float TargetX = OppSign * Math::Lerp(350.0f, 700.0f, Difficulty);

		// Aim to whichever Y half is less defended — approximate by aiming
		// opposite our own attacker's Y, with error that shrinks with skill
		float AimY = (GetActorLocation().Y > 0) ? -250.0f : 250.0f;
		float Error = Math::RandRange(-180.0f, 180.0f) * (1.0f - Difficulty);
		AimY = Math::Clamp(AimY + Error, CourtMinY + 60.0f, CourtMaxY - 60.0f);

		return FVector(TargetX, AimY, FloorZ + BallRadiusGuess());
	}

	private float BallRadiusGuess() const { return (Ball != nullptr) ? Ball.BallRadius : 10.66f; }

	// ---------------------------------------------------------------
	// Positioning helpers
	// ---------------------------------------------------------------
	private FVector SupportPos(FVector Landing) const
	{
		float Sign = MySign();
		if (Role == EPlayerRole::Role_Front)
		{
			// Front player: stay at net ready to attack, track ball Y
			float Y = Math::Clamp(Landing.Y, CourtMinY + 100.0f, CourtMaxY - 100.0f);
			return FVector(Sign * 170.0f, Y, FloorZ + PlayerHeight);
		}
		else
		{
			// Back player: cover deep court behind the attacker
			float Y = Math::Clamp(Landing.Y * 0.5f, CourtMinY + 100.0f, CourtMaxY - 100.0f);
			return FVector(Sign * 620.0f, Y, FloorZ + PlayerHeight);
		}
	}

	// ---------------------------------------------------------------
	// Defense: the ball is on the opponent's side. Two defenders split the court
	// (one covers each Y half) UNLESS it's a clear jump-spike threat at the net —
	// then the front player blocks at the net and the back player covers the line
	// behind the block.
	// ---------------------------------------------------------------
	private void PlayDefense(float DeltaTime)
	{
		FVector Goal;
		AAIPlayer Attacker = FindAttackingOpponent();
		// Default assumption: the opponent WILL spike, so we commit to the block.
		// We only drop OFF the block once their pass/set turns out to be poor (too
		// far off the net or too low to attack) — then there's nothing to block and
		// we fall back into court defense.
		bool bAttackable = IsPassAttackable();

		if (Role == EPlayerRole::Role_Front && bAttackable)
		{
			// BLOCK, with discipline. Grounded at the net = LOW ready stance,
			// hands loaded — never arms-up statue. The block jump keys off the
			// real cue elite blockers use: the ATTACKER LEAVING THE GROUND (with a
			// fast-descending ball at the net as fallback). Arms go up only once
			// we're airborne; the IK reaches the hands to the ball.
			float NetX = MySign() * 55.0f;   // right up at the net on our side
			float BlockY = Math::Clamp(Ball.Position.Y, CourtMinY + 60.0f, CourtMaxY - 60.0f);
			Goal = FVector(NetX, BlockY, FloorZ + PlayerHeight);

			// Aim the block at the middle of the opponent's court so a stuffed ball
			// drops there (DesiredAim drives the hand angle in UpdateIKTargets).
			AimAt(FVector(-MySign() * 300.0f, 0.0f, FloorZ));

			AAIPlayer Att = FindAttackingOpponent();
			bool bAttackerAirborne = (Att != nullptr && !Att.bIsGrounded);
			bool bBallNearNet = Math::Abs(Ball.Position.X) < 350.0f && Ball.Position.Z > 220.0f;
			bool bSpikeIncoming = (bAttackerAirborne && bBallNearNet)
				|| (bBallNearNet && Ball.BallVel.Z < -250.0f);   // already smashed/dropping fast

			if (bIsGrounded)
			{
				float Horiz = (GetActorLocation() - FVector(Goal.X, Goal.Y, 0)).Size2D();
				if (bSpikeIncoming && Horiz < 90.0f)
				{
					// Kill the drive FIRST so the block jump is vertical — momentum
					// carries in the air, and drifting into the net is a fault.
					MovePlayer(FVector2D::ZeroVector);
					float HSpd = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size();
					if (HSpd < 90.0f)
						Jump();
				}
				else
				{
					// Track the ball along the net in a loaded stance, hands low.
					MoveToward2D(Goal, DeltaTime, false, 0.85f);
					RequestCrouch(0.3f);
				}
			}
			else
			{
				// Airborne: hold still (no drift) and throw up the block NOW.
				MovePlayer(FVector2D::ZeroVector);
				Reach(EHitType::Hit_Block);
			}
			if (bDebugAI) Log(DebugTag() + " DEFEND BLOCK ballZ=" + int(Ball.Position.Z)
				+ " air=" + !bIsGrounded + " incoming=" + bSpikeIncoming);
			return;
		}
		else if (Role == EPlayerRole::Role_Back && bAttackable)
		{
			// Back defender covers deep behind the block, toward the open court the
			// blocker isn't taking away.
			float DeepX = MySign() * 600.0f;
			float CoverY = (Attacker != nullptr)
				? Math::Clamp(-Attacker.GetActorLocation().Y * 0.6f, CourtMinY + 80.0f, CourtMaxY - 80.0f)
				: 0.0f;
			Goal = FVector(DeepX, CoverY, FloorZ + PlayerHeight);
		}
		else
		{
			// Pass was poor / no attack coming — drop off the block and split the
			// court so each defender owns a Y half at a FIXED defensive spot. No
			// per-frame leaning toward the ball: that caused constant shuffling.
			// Stand still on your half and react only when the ball comes over.
			float Depth = (Role == EPlayerRole::Role_Front) ? MySign() * 250.0f : MySign() * 560.0f;
			float HalfCenter = (Role == EPlayerRole::Role_Front) ? -200.0f : 200.0f;
			Goal = FVector(Depth, HalfCenter, FloorZ + PlayerHeight);
		}

		if (bDebugAI) Log(DebugTag() + " DEFEND " + (bAttackable ? "BLOCK/COVER" : "SPLIT")
			+ " ballX=" + int(Ball.Position.X) + " ballZ=" + int(Ball.Position.Z));
		// Take the defensive spot and HOLD it, facing the play — in a LOW athletic
		// base, never flat-footed upright: a defender waiting tall reads amateur.
		// Jog into position facing the travel; face up once settled.
		Goal = ClampToCourt(Goal);
		MoveToHold(Goal, DeltaTime, 0.75f);
		RequestCrouch(0.22f);
		if ((Goal - GetActorLocation()).Size2D() < 150.0f)
			FaceAttacker();
	}

	// Find the opponent who is about to hit — the one closest to the ball on the
	// other side of the net.
	private AAIPlayer FindAttackingOpponent() const
	{
		TArray<AActor> Players;
		GetAllActorsOfClass(AVolleyballPlayer, Players);
		AAIPlayer Best = nullptr;
		float BestDist = 99999.0f;
		for (AActor A : Players)
		{
			AAIPlayer P = Cast<AAIPlayer>(A);
			if (P == nullptr || P.TeamSide == TeamSide) continue;   // only opponents
			float D = (P.GetActorLocation() - Ball.Position).Size();
			if (D < BestDist) { BestDist = D; Best = P; }
		}
		return Best;
	}

	// Remembered block/drop decision, with HYSTERESIS so it doesn't flip every frame
	// (which made players run back and forth). Once committed to the block we hold it
	// until the pass is CLEARLY un-attackable; once dropped we don't re-commit until
	// the ball is CLEARLY attackable again. The two thresholds don't overlap.
	private bool bCommittedToBlock = false;

	private bool IsPassAttackable()
	{
		// A block is only ever an answer to the opponent BUILDING an attack — they
		// must have touched the ball this possession. Serves and balls we just
		// sent over are met in receive formation, never at the net (nobody blocks
		// a serve; committing the front player to the net against serves forced a
		// hopeless 3m backpedal whenever the serve turned out to be his).
		ABeachVolleyballGameState GSB = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		ETeam Opp = (TeamSide == ETeam::Team_A) ? ETeam::Team_B : ETeam::Team_A;
		if (GSB == nullptr || GSB.LastTouchTeam != Opp || GSB.TouchesThisRally < 1)
		{
			bCommittedToBlock = false;
			return false;
		}

		float BallOffNet = Math::Abs(Ball.Position.X);
		float BallZ = Ball.Position.Z;
		bool bOpponentSide = (TeamSide == ETeam::Team_A) ? Ball.Position.X > -50.0f
		                                                 : Ball.Position.X <  50.0f;

		if (!bOpponentSide)
		{
			bCommittedToBlock = false;
			return false;
		}

		if (bCommittedToBlock)
		{
			// Stay on the block until the pass is clearly bad: well off the net OR
			// dropped low. Wide margins so small ball motion doesn't drop the block.
			if (BallOffNet > 420.0f || BallZ < 110.0f)
				bCommittedToBlock = false;
		}
		else
		{
			// Commit to the block only when the ball is clearly a real attack setup:
			// near the net and high. Tighter than the drop thresholds (hysteresis gap).
			if (BallOffNet < 300.0f && BallZ > 170.0f)
				bCommittedToBlock = true;
		}

		return bCommittedToBlock;
	}

	// ---------------------------------------------------------------
	// Queries
	// ---------------------------------------------------------------
	private float MySign() const { return (TeamSide == ETeam::Team_A) ? -1.0f : 1.0f; }

	private int TeamTouches() const
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr) return 0;
		// Only count touches that belong to our team this rally
		if (GS.LastTouchTeam == TeamSide) return GS.TouchesThisRally;
		return 0;  // ball just crossed to us — this is our receive (touch 0)
	}

	// Should our team actively go play the ball right now? Only when the ball is
	// genuinely on our side of the net — not while it's still high over the
	// opponent's court (even if it's predicted to eventually cross to us).
	private bool IsBallComingToMySide() const
	{
		bool bBallOnMySide = (TeamSide == ETeam::Team_A) ? Ball.Position.X <= 0.0f
		                                                 : Ball.Position.X >= 0.0f;

		// If the ball is physically on our side, it's ours to play.
		if (bBallOnMySide) return true;

		// Ball is on the opponent's side. Only commit early if it has clearly
		// crossed toward us (moving to our side AND already low enough that the
		// predicted landing is on our court) — otherwise hold and defend.
		bool bMovingToMe = (TeamSide == ETeam::Team_A) ? Ball.BallVel.X < -50.0f
		                                               : Ball.BallVel.X >  50.0f;
		if (!bMovingToMe) return false;

		FVector Landing = Ball.PredictLanding();
		bool bLandMine = (TeamSide == ETeam::Team_A) ? Landing.X <= 0.0f
		                                             : Landing.X >= 0.0f;
		if (!bLandMine) return false;

		// If the opponent will NOT touch this ball again — it's a serve in
		// flight, or their third (final) touch is already over — CHARGE NOW.
		// The receive needs every tenth of flight time: waiting for the ball to
		// reach the net gave the receiver 0.35s to cover the last 1.4m and made
		// clean serves into aces. While they're still building (touches 1-2),
		// hold the defensive shape until the ball is actually near the net.
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS != nullptr)
		{
			ETeam Opp = (TeamSide == ETeam::Team_A) ? ETeam::Team_B : ETeam::Team_A;
			bool bServeIncoming = (GS.LastTouchTeam == ETeam::Team_None && GS.ServingTeam == Opp);
			bool bAttackOver = (GS.LastTouchTeam == Opp && GS.TouchesThisRally >= 3);
			if (bServeIncoming || bAttackOver) return true;
		}
		// Require the ball to be near or past the net before charging in.
		return Math::Abs(Ball.Position.X) < 250.0f;
	}

	private bool IsDeep(float X) const
	{
		if (TeamSide == ETeam::Team_A) return X < -350.0f;
		return X > 350.0f;
	}

	// Horizontal reach to the ball's current position
	private bool IsWithinReach() const
	{
		FVector ToBall = Ball.Position - GetActorLocation();
		return ToBall.Size2D() < 110.0f;
	}

	private FVector ClampToCourt(FVector P) const
	{
		return FVector(
			Math::Clamp(P.X, CourtMinX + 40.0f, CourtMaxX - 40.0f),
			Math::Clamp(P.Y, CourtMinY + 40.0f, CourtMaxY - 40.0f),
			FloorZ + PlayerHeight);
	}

	// ---------------------------------------------------------------
	// Movement (no auto-jump here — jumping is decided by spike logic)
	// ---------------------------------------------------------------
	private void MoveToward2D(FVector Target, float Dt, bool bSprint = false, float SpeedCap = 1.0f)
	{
		FVector Dir = Target - GetActorLocation();
		Dir.Z = 0;
		float D = Dir.Size2D();
		// The stop zone must exceed the braking distance from the slowest arrive
		// speed (GroundDecel brakes ~9cm from 250cm/s) — an 8cm zone made the
		// player overshoot, flip direction and shake at frame rate on the spot.
		if (D <= 25.0f)
		{
			MovePlayer(FVector2D::ZeroVector);
			return;
		}

		// Pros decelerate INTO position (gather step) instead of running full tilt
		// and stopping dead — except on a committed spike approach (bSprint).
		// SpeedCap lets callers hustle only as fast as the situation demands.
		float Scale = bSprint ? 1.0f : Math::Min(Math::Clamp(D / 150.0f, 0.25f, 1.0f), SpeedCap);

		// During the split step the feet are planted; only a tiny shuffle allowed.
		if (SplitStepTimer > 0.0f)
			Scale *= 0.12f;

		FVector N = Dir.GetSafeNormal2D();
		MovePlayer(FVector2D(N.X * Scale, N.Y * Scale));
	}

	// --- Split step: the signature read-and-react habit of elite defenders — a
	// quick loading dip with planted feet the instant the OPPONENT strikes the
	// ball (or the serve launches), THEN explode toward the read.
	protected float SplitStepTimer = 0.0f;
	const float SplitStepDuration = 0.26f;
	private int PrevTouchStamp = -1;
	private bool bPrevBallInPlay = false;

	protected void UpdateSplitStep(float Dt)
	{
		if (SplitStepTimer > 0.0f)
		{
			SplitStepTimer -= Dt;
			// Dip envelope: sink and rise over the duration.
			float Prog = 1.0f - SplitStepTimer / SplitStepDuration;
			ExtraCrouch = Math::Max(ExtraCrouch, 0.5f * Math::Sin(Prog * PI));
		}
		if (Ball == nullptr) return;

		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr) return;

		// Serve launch: the ball just went live against us.
		if (Ball.bInPlay && !bPrevBallInPlay && GS.ServingTeam != TeamSide)
			SplitStepTimer = SplitStepDuration;
		bPrevBallInPlay = Ball.bInPlay;

		// Opponent contact: their touch team/count just changed.
		int Stamp = int(GS.LastTouchTeam) * 100 + GS.TouchesThisRally;
		if (Stamp != PrevTouchStamp)
		{
			if (GS.LastTouchTeam != TeamSide && GS.LastTouchTeam != ETeam::Team_None && Ball.bInPlay)
				SplitStepTimer = SplitStepDuration;
			PrevTouchStamp = Stamp;
		}
	}

	// Positional "hold": move to the target, but once we arrive STAY PUT until the
	// target drifts well away. This kills the constant micro-shuffling during
	// defense/support — you take your spot, face up, and stand still. Hysteresis:
	// start moving only past StartMoving, stop as soon as within Arrived.
	private bool bHolding = false;
	protected void MoveToHold(FVector Target, float Dt, float SpeedCap = 1.0f)
	{
		const float StartMoving = 110.0f;   // must drift this far before we re-chase
		const float Arrived     = 35.0f;    // close enough — plant and hold
		float D = (Target - GetActorLocation()).Size2D();

		if (bHolding)
		{
			if (D > StartMoving) bHolding = false;   // target moved a lot; reposition
		}
		else
		{
			if (D <= Arrived) bHolding = true;        // arrived; lock in place
		}

		if (bHolding)
			MovePlayer(FVector2D::ZeroVector);        // stand still
		else
			MoveToward2D(Target, Dt, false, SpeedCap);
	}

	// ---------------------------------------------------------------
	// The base player registers the touch when the ball physically bounces off
	// us; we just record that it was us, so the teammate takes the next contact.
	void OnTouchRegistered() override
	{
		bIMadeLastTouch = true;
		if (Teammate != nullptr)
			Teammate.bIMadeLastTouch = false;
	}

	// No two contacts in a row — I'm transparent to the ball right after I hit it.
	bool CanContactBall() const override
	{
		return !bIMadeLastTouch;
	}

	protected void FindBall()
	{
		TArray<AActor> Found;
		GetAllActorsOfClass(ABall, Found);
		if (Found.Num() > 0)
			Ball = Cast<ABall>(Found[0]);
	}
}
