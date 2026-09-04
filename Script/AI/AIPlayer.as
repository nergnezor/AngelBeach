// AI player - volleyball state machine: Receive -> Set -> Attack with proper
// roles, height-aware contacts, and team coordination (no flip-flopping).

enum EPlayerRole { Role_Back, Role_Front }

// What a player is doing right now — see SetPlayState. Exactly one is active.
enum EPlayState { Play_Base, Play_Block, Play_Job }

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
			RunServeSequence(DeltaTime);
		else
			RunAIBrain(DeltaTime);

		// WATCHING THE BALL IS PERCEPTION, NOT DECISION — so it runs at full
		// frame rate, above the decision cadence, exactly like the split step.
		//
		// This is the shake, measured rather than guessed at. FaceBall() used to
		// live only inside UpdateAI, which sits behind BOTH the 0.16s perception
		// blackout and the ~0.11s reaction gate, while a facing request expires
		// after FacingHoldTimer = 0.2s. Any ball touch therefore opened a gap of
		// up to 0.27s containing no facing request at all. The hold lapsed, the
		// rotation authority fell through to its next source — travel-facing,
		// 15-40 deg away — the body swung there, and swung back when the brain
		// resumed. The waveform trace shows it plainly: src goes 1 -> 0 -> 1 and
		// the target makes a ~40 deg round trip with it, every touch.
		//
		// It is reported as "before every receive" because a touch is precisely
		// what sends a ball toward a receiver, so the blackout fires on the
		// approach every single time.
		//
		// Note the old comment on the perception gate claimed "the facing hold
		// carries the old intent through the gap". It could not: 0.2 < 0.27. The
		// repair is not a longer hold — that is the same coincidence-of-constants
		// that keeps breaking — but taking eye tracking out of the decision path,
		// which is also where it belongs physically. A player does not stop
		// looking at the ball for 160ms while deciding what to do about it.
		//
		// Guarded on bHasFacing so a branch that ran this frame and asked for
		// something MORE specific (the spike approach's open shoulder, a dive)
		// still wins; this only fills the frames where nothing asked at all.
		//
		// STOPPED ONLY. This used to fire every in-play frame with no other
		// request — including every jog back to base and every dig approach we
		// had just stopped FaceBall()-ing. FacingHoldTimer never lapsed, the
		// body stayed chest-to-ball, and travel ran the other way: the exact
		// "böjer sig framåt och backar" look. The vibration this exists to
		// kill is a PLANTED receiver rocking when the hold gaps; a moving
		// player should face travel (UpdatePlayer) and does not need this.
		float WatchHSpeed = FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size();
		if (!bHasFacing && !bServing && Ball != nullptr && Ball.bInPlay && !IsDiving()
			&& WatchHSpeed < 80.0f)
			RequestBallFacing();
	}

	// The dead-ball reset, perception latency and reaction gate, in one place.
	// AHumanPlayer runs the same brain as its fallback and used to carry its own
	// copy of this sequence — a copy that had drifted: it was missing the whole
	// perception-latency block and every per-rally reset, so Team A's back player
	// reacted to ball events with zero delay and carried stale commitment flags
	// (bIntendSet, bOnTwoDecided, a plant that PLANVA measures settle time from)
	// across rallies. It was also the player that logs nothing, since bDebugAI is
	// only set on B1/B2. Shared, it cannot diverge again.
	// Returns true if the caller should stop here for this frame.
	protected bool RunAIBrain(float DeltaTime)
	{
		if (Ball == nullptr || !Ball.bInPlay)
		{
			bIMadeLastTouch = false;
			PlanSlackLog = -1.0f;   // an unconsumed promise must not leak into the next rally
			bHitterPlanted = false; // ...nor a stale plant (PLANVA settle counts from it)
			PlantedFacing = FVector::ZeroVector;
			PlantedFor = 0.0f;
			bOnTwoDecided = false;  // per-ball decisions die with the ball
			bChoseOnTwo = false;
			bIntendSet = false;
			bOnTwoLoggedNotViable = false;
			bSpikeCueOn = false;    // a committed attack cue must not outlive its ball
			bServeRecvLogged = false;
			bRecvPlanLogged = false;
			// Start every rally in Base with the dwell already spent. StateDwell
			// only advances inside UpdateAI, which the dead ball returns before —
			// so without this a player carried the previous rally's state AND a
			// frozen dwell into the next serve, and could be barred from taking
			// the Job for up to 0.35s of a ~1.7s serve flight. The dwell exists
			// to stop mid-rally churn, not to make players slow off the mark.
			PlayState = EPlayState::Play_Base;
			StateDwell = StateMinDwell;

			// The one player the GameMode nominated fetches the ball instead of
			// strolling to formation. RunFetchSequence returns false once it is
			// finished, so they fall straight through to the normal reset below.
			if (bFetching && RunFetchSequence(DeltaTime))
				return true;

			MoveToHold(ReadyPosition(), DeltaTime, 0.7f);
			PreFaceForServe();
			return true;
		}

		// PLAN vs ACTUAL bookkeeping: how long the hitter has stood planted
		// (read by OnBallContact's PLANVA telemetry line).
		PlantedFor = bHitterPlanted ? PlantedFor + DeltaTime : 0.0f;
		if (!bHitterPlanted)
			PlantedFacing = FVector::ZeroVector;

		// PERCEPTION LATENCY (first principles): a ball EVENT — any touch, the
		// serve going live — is not seen instantly. The previous action keeps
		// running for a visual-reaction beat before any re-planning; stored
		// move input and the facing hold carry the old intent through the gap.
		// The split step is exempt above: it is anticipatory, not a reaction.
		ABeachVolleyballGameState PGS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		int PerceptStamp = (PGS != nullptr)
			? int(PGS.LastTouchTeam) * 100 + PGS.TouchesThisRally + (Ball.bInPlay ? 1000 : 0)
			: -1;
		if (PerceptStamp != PrevPerceptStamp)
		{
			PrevPerceptStamp = PerceptStamp;
			PerceptionTimer = PerceptionLatency;
		}
		if (PerceptionTimer > 0.0f)
		{
			PerceptionTimer -= DeltaTime;
			return true;
		}

		ReactionTimer += DeltaTime;
		if (ReactionTimer < ReactionDelay) return true;
		ReactionTimer = 0.0f;

		UpdateAI(DeltaTime);
		return false;
	}

	// Human visual reaction to an unanticipated event (~0.16s). Separate from
	// ReactionDelay (the decision cadence): this one fires per EVENT.
	const float PerceptionLatency = 0.16f;
	private float PerceptionTimer = 0.0f;
	private int PrevPerceptStamp = -12345;

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

		// RECEIVING: the base formation — the same spot a player returns to any
		// time they have no job (see BasePosition). One definition, so serve
		// receive and in-rally reset cannot drift apart.
		//
		// It used to fall through to HomePosition(), the RALLY formation: front
		// player 250cm off the net (a blocking spot) and the pair only 240cm
		// apart in Y. Nobody blocks a serve, and two receivers that close leave
		// both sidelines open — the front player stood at the net while the
		// serve landed five metres behind them.
		return BasePosition();
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
	//
	// Gated on bHolding (MoveToHold's "arrived and standing still" flag, set by
	// the MoveToHold(ReadyPosition(), ...) call this same tick, just above ours
	// in the dead-ball branch): forcing the net-facing unconditionally, from the
	// moment the ball goes dead, held it for the ENTIRE walk back to the baseline
	// spot — including legs whose actual travel was AWAY from the net. Facing
	// net while translating away from it is a backward walk (MoveDirAngle ≈
	// 180), which is exactly the "runs toward the net but moves backwards" look.
	// Waiting for arrival means the turn happens while planted (pure rotation,
	// no translation to mismatch), well before RunServeSequence needs it.
	protected void PreFaceForServe()
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr || GS.ServingTeam != TeamSide || Role != EPlayerRole::Role_Back)
			return;
		if (!bHolding)
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
		Reach(EHitType::Hit_Serve, Ball.Position);   // serve builds its own motion from ServePhase
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
				// The script-computed hand TARGET, not the solved bone — see
				// ServeTossTarget's comment in VolleyballPlayer.as. +16 keeps
				// the ball riding above the palm the same way the old
				// bone-read offset did.
				FVector Carry = ServeTossTarget + FVector(0, 0, 16);
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
				Log("SERVELAUNCH pos=(" + int(Ball.Position.X) + "," + int(Ball.Position.Y)
					+ "," + int(Ball.Position.Z) + ") vel=(" + int(PendingServeVel.X)
					+ "," + int(PendingServeVel.Y) + "," + int(PendingServeVel.Z) + ")"
					+ " yaw=" + int(GetActorRotation().Yaw) + " actorZ=" + int(GetActorLocation().Z));
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
	// Dead-ball retrieval: walk to the ball, pick it up, throw it to
	// where the next server is heading. Driven entirely from the dead-ball
	// branch of RunAIBrain; the GameMode picks who does it (ChooseFetcher).
	// ---------------------------------------------------------------
	bool bFetching = false;
	private int FetchState = 0;        // 0 walk to ball, 1 pick up, 2 back off, 3 throw, 4 done
	private float FetchTimer = 0.0f;
	private FVector FetchTarget = FVector::ZeroVector;   // where the next server is going
	private FVector ThrowFrom = FVector::ZeroVector;
	private FVector ThrowVel = FVector::ZeroVector;
	private float ThrowFlightTime = 0.0f;

	// How close to stand before picking the ball up, and the beat spent bending
	// for it. Reach is generous: the ball rests ON the sand, the hand comes to it.
	const float FetchReach = 70.0f;
	const float PickupDuration = 0.35f;
	// Minimum distance from the net to throw ACROSS it from. A ball fetched at
	// the net cannot be lobbed over it on any sane arc — the required flight time
	// diverges as the throw start approaches X=0 — so carry it back this far
	// first. At 260 the arc peaks ~315cm over a 243cm net; see ThrowArc below.
	const float MinCrossThrowX = 260.0f;

	// Am I settled on my dead-ball formation spot? The GameMode polls every
	// player to decide when to serve, instead of counting down a fixed timer:
	// the serve now waits for the ball to be delivered and everyone to walk
	// into position, which is what actually ends a beach volleyball dead ball.
	//
	// Radius is comfortably wider than MoveToHold's 35cm Arrived so a player who
	// has planted and is holding always reads as ready — matching the hold
	// threshold exactly would leave them one centimetre short forever.
	const float ReadyRadius = 90.0f;

	bool IsInReadyPosition() const
	{
		if (bFetching) return false;   // still carrying or throwing the ball
		return (GetActorLocation() - ReadyPosition()).Size2D() < ReadyRadius;
	}

	void BeginFetch(FVector ThrowTarget)
	{
		bFetching = true;
		FetchState = 0;
		FetchTimer = 0.0f;
		FetchTarget = ThrowTarget;
	}

	void EndFetch()
	{
		bFetching = false;
		FetchState = 4;
	}

	// Returns true while the fetch owns this player's movement.
	protected bool RunFetchSequence(float Dt)
	{
		if (Ball == nullptr || Ball.bInPlay || Mesh == nullptr) { bFetching = false; return false; }

		FVector Me = GetActorLocation();

		if (FetchState == 0)   // walk to the ball
		{
			FVector Goal = FVector(Ball.Position.X, Ball.Position.Y, Me.Z);
			MoveToHold(Goal, Dt, 1.0f);
			FaceToward(Ball.Position);
			if ((Me - Goal).Size2D() < FetchReach)
			{
				FetchState = 1;
				FetchTimer = 0.0f;
			}
			return true;
		}

		if (FetchState == 1)   // bend down and pick it up
		{
			MovePlayer(FVector2D::ZeroVector);
			FaceToward(FetchTarget);
			CarryBall();
			FetchTimer += Dt;
			if (FetchTimer >= PickupDuration)
			{
				FetchState = 2;
				FetchTimer = 0.0f;
			}
			return true;
		}

		if (FetchState == 2)   // carry clear of the net if the throw has to cross it
		{
			CarryBall();
			bool bCrossesNet = (FetchTarget.X * MySign()) < 0.0f;
			if (!bCrossesNet || Math::Abs(Me.X) >= MinCrossThrowX)
			{
				StartThrow();
				return true;
			}
			// Back away from the net along my own half, still facing the target.
			MoveToHold(FVector(MySign() * (MinCrossThrowX + 40.0f), Me.Y, Me.Z), Dt, 1.0f);
			FaceToward(FetchTarget);
			return true;
		}

		if (FetchState == 3)   // ball in the air
		{
			MovePlayer(FVector2D::ZeroVector);
			FaceToward(FetchTarget);
			FetchTimer += Dt;
			// CLOSED-FORM flight, same reasoning as the serve toss above: a frame
			// hitch must not be able to integrate the ball through the floor.
			float T = Math::Min(FetchTimer, ThrowFlightTime);
			FVector P = ThrowFrom + ThrowVel * T + FVector(0, 0, -490.0f * T * T);
			Ball.Position = P;
			Ball.BallVel = FVector::ZeroVector;
			Ball.SetActorLocation(P);
			if (FetchTimer >= ThrowFlightTime)
			{
				FetchState = 4;
				bFetching = false;
				Log("FETCH done " + GetName() + " restX=" + int(P.X) + " restY=" + int(P.Y));
			}
			return true;
		}

		bFetching = false;
		return false;
	}

	// The established carry idiom (see RunServeSequence): write position AND
	// actor location every frame. Safe without fighting physics because the
	// ball's Tick early-outs while bInPlay is false.
	private void CarryBall()
	{
		FVector Carry = Mesh.GetBoneTransform(n"hand_r").Location + FVector(0, 0, 12);
		Ball.Position = Carry;
		Ball.BallVel = FVector::ZeroVector;
		Ball.SetActorLocation(Carry);
	}

	private void StartThrow()
	{
		ThrowFrom = Ball.Position;
		FVector D = FetchTarget - ThrowFrom;
		// Flight time from distance, floored so short throws still arc rather
		// than firing flat, capped so long ones do not hang past the serve.
		ThrowFlightTime = Math::Clamp(D.Size2D() / 700.0f, 0.9f, 1.8f);
		float T = ThrowFlightTime;
		// Solve P0 + V*T - 490*T^2 = Target for V (gravity matches the serve toss).
		ThrowVel = FVector(D.X / T, D.Y / T, D.Z / T + 490.0f * T);
		FetchState = 3;
		FetchTimer = 0.0f;
	}

	private void FaceToward(FVector P)
	{
		FVector To = P - GetActorLocation();
		To.Z = 0.0f;
		if (To.SizeSquared() > 1.0f)
		{
			FacingDir = To.GetSafeNormal();
			bHasFacing = true;
		}
	}

	// ---------------------------------------------------------------
	// Main decision loop (protected so AHumanPlayer can reuse it as its
	// AI fallback when no gamepad input is active)
	// ---------------------------------------------------------------
	// ---------------------------------------------------------------
	// WHAT AM I DOING RIGHT NOW — asked once, answered once.
	//
	// Twelve call sites used to command movement, half of them through a
	// primitive with no hysteresis at all, and nothing ever asked this question
	// as ONE question. That is why they could fight each other: two subsystems
	// would each decide they owned the body on alternating AI ticks and the
	// player shuttled between their two goals. Every previous fix bolted a
	// hysteresis band onto whichever boolean was caught oscillating that week,
	// which is a losing game — there is always another boolean.
	//
	// The model, in Erik's words: always follow the ball with your eyes, always
	// move toward your receive position, EXCEPT when you must move to do
	// something with the ball — plus blocking, which is a real position at the
	// net and neither of those.
	//
	//   Job   — this ball is mine to play. Go to the contact.
	//   Block — the opponent is attacking and the net is mine. Hold it.
	//   Base  — everything else. Walk to base, watch the ball.
	//
	// Exactly one is active per tick, and a state must be held for StateMinDwell
	// before another can take over. That dwell is the single arbitration point
	// the codebase never had: it does not matter how noisy an individual
	// predicate is if the STATE it feeds cannot change faster than a person can.
	private EPlayState PlayState = EPlayState::Play_Base;
	private float StateDwell = 0.0f;
	// Long enough that no predicate can drive a visible shuttle (the AI ticks at
	// ~9Hz, so this is ~3 ticks), short enough not to be felt as sluggishness.
	const float StateMinDwell = 0.35f;

	private void SetPlayState(EPlayState Want)
	{
		if (Want == PlayState) return;
		if (StateDwell < StateMinDwell) return;   // too soon — hold what we have
		PlayState = Want;
		StateDwell = 0.0f;
		if (bDebugAI) Log(DebugTag() + " STATE=" + int(Want));
	}

	protected void UpdateAI(float DeltaTime)
	{
		StateDwell += DeltaTime;

		bool bMine = IsBallComingToMySide();
		if (!bMine)
		{
			// Ball is on the opponent's side: clear our touch-ownership so the
			// next receive starts fresh.
			bIMadeLastTouch = false;
			bOnTwoDecided = false;
			bChoseOnTwo = false;
			bIntendSet = false;
			bOnTwoLoggedNotViable = false;
		}

		FVector Landing = Ball.PredictLanding();
		bool bWantJob = bMine && AmIHitter(Landing);
		bool bWantBlock = !bMine && Role == EPlayerRole::Role_Front && IsPassAttackable();

		if (bWantJob && Teammate != nullptr && Teammate.bIMadeLastTouch
			&& PlayState != EPlayState::Play_Job)
		{
			// My teammate just made THEIR touch: the digger!=setter!=attacker
			// invariant (CanContactBall/bIMadeLastTouch) guarantees it is
			// unambiguously my turn now, not a noisy predicate. MEASURED: an
			// attacker's own Play_Base dwell often starts only 50-100ms before
			// the set (the whole dig-to-set gap), so it hasn't matured past
			// StateMinDwell yet when the set lands — going through the normal
			// debounced SetPlayState() here delayed entry into ApproachForSpike
			// by up to 300ms, well past a set's ~750-800ms jump-spike peak.
			PlayState = EPlayState::Play_Job;
			StateDwell = 0.0f;
		}
		else if (bWantJob)    SetPlayState(EPlayState::Play_Job);
		else if (bWantBlock)  SetPlayState(EPlayState::Play_Block);
		else if (bIMadeLastTouch && PlayState == EPlayState::Play_Job)
		{
			// I just made my own touch: CanContactBall() (!bIMadeLastTouch)
			// guarantees I cannot be reselected as hitter this rally, so this
			// is a hard fact, not a noisy predicate StateMinDwell needs to
			// debounce. MEASURED: the AI ticks at ~9Hz and a dig-to-set gap
			// can be faster than StateMinDwell's 3-tick hold, which stranded
			// the digger in Job for the ENTIRE touch=1 window — PlayBase()'s
			// attacker-anticipation branch never got a single tick to run.
			PlayState = EPlayState::Play_Base;
			StateDwell = 0.0f;
		}
		else                  SetPlayState(EPlayState::Play_Base);

		// Watch the ball only when planted or in a job that needs it. Unconditional
		// FaceBall() here held net/ball-facing for every jog back to base — the
		// classic "bent forward and backpedaling" look on PlayBase repositioning.
		// PlayHitter / PlayBlock still request it themselves; turn-and-run can
		// override when travel fights the facing.
		if (PlayState == EPlayState::Play_Job)
		{
			if (bDebugAI) Log(DebugTag() + " JOB t=" + TeamTouches());
			PlayHitter(TeamTouches(), DeltaTime);
		}
		else if (PlayState == EPlayState::Play_Block)
		{
			FaceBall();
			PlayBlock(DeltaTime);
		}
		else
		{
			PlayBase(DeltaTime);
		}
	}

	// BASE: walk to my own receive spot and wait, low and watching. One target,
	// constant per player, so this state cannot contribute jitter at all.
	// WHERE MY PARTNER'S DIG WILL ARRIVE. The mirror of PassTarget(): they aim
	// at my half of the centre line, so this is that same point, for me.
	private FVector PassReceiveSpot() const
	{
		float AimY = (Role == EPlayerRole::Role_Front) ? -120.0f : 120.0f;
		return FVector(MySign() * 180.0f, AimY, FloorZ + PlayerHeight);
	}

	private void PlayBase(float DeltaTime)
	{
		if (bDebugAI) Log(DebugTag() + " BASE");

		// A SETTER DOES NOT WAIT FOR THE DIG. While my partner is playing the
		// first ball, the pass is already coming to a known spot — release
		// toward it now instead of standing at base until it is in the air.
		//
		// MEASURED without filtering, at the instant the rally died: 23 of 33
		// rallies ended after ONE touch, with the nearest player 180cm from the
		// ball and not even reaching (21%). The budget is why: 3.4m in the 1.4s
		// a pass hangs needs 1.08s of travel plus 0.28s of reaction — no margin
		// at all, and that is before the prediction has settled.
		// BOTH BRANCHES BELOW REQUIRE THE BALL TO BE ON OUR SIDE. TeamTouches()
		// answers "how many touches has my team made", not "is the ball here":
		// if our first touch went over the net it still reads 1 while the ball
		// is on the opponent's court, and the attacker would jog to the pin
		// while the ball comes back at them. Reported from play as "spelarna
		// springer fortfarande bort från bollen inför 3:e-slaget".
		bool bMateHasIt = Teammate != nullptr && !Teammate.bRagdollActive
			&& Teammate.bWasHitter && IsBallComingToMySide();
		if (bMateHasIt && TeamTouches() == 0)
		{
			MoveToHold(ClampToCourt(PassReceiveSpot()), DeltaTime, 0.75f);
			if (bHolding) { RequestCrouch(0.22f); FaceBall(); }
			return;
		}
		// ...AND AN ATTACKER DOES NOT WAIT FOR THE SET, for exactly the reason
		// the setter no longer waits for the dig. While my partner plays the
		// SECOND ball, the set is going to a known place — my own pin, since
		// that is what PartnerPinTarget() aims at from their side — and the
		// run-up starts 200cm behind it. Standing at base until the set is in
		// the air leaves 4.5m to cover in the time a set hangs.
		//
		// Reported from play as "det är aldrig någon som är förberedd på att
		// slå tredje touchen", which is the same shape as the second-ball bug
		// fixed in 1729e83: the coverage was written for a ball that never
		// arrived, so nobody was where it went.
		if (bMateHasIt && TeamTouches() == 1)
		{
			MoveToHold(MyPinApproachStart(), DeltaTime, 0.75f);
			if (bHolding) FaceBall();
			return;
		}

		MoveToHold(ClampToCourt(BasePosition()), DeltaTime, 0.75f);
		// Crouch + ball-face only when ARRIVED. Asking for both while jogging
		// back to base is exactly "böjer sig framåt och backar": chest toward
		// the ball/net, travel toward the baseline, hips sunk for a dig that
		// isn't happening yet. Head LookAt still tracks the ball every frame.
		if (bHolding)
		{
			RequestCrouch(0.22f);
			FaceBall();
		}
	}

	// The one spot a player returns to whenever they have no job. Same formation
	// as serve receive, used during rallies too: it is where you want to be when
	// you do not know where the ball is going, which is exactly what "no job"
	// means. Deliberately NOT derived from the ball — a base that tracks the
	// ball is just another moving goal.
	FVector BasePosition() const
	{
		float Sign = MySign();
		float Z = FloorZ + PlayerHeight;
		if (Role == EPlayerRole::Role_Front)
			return FVector(Sign * 500.0f, -190.0f, Z);
		return FVector(Sign * 560.0f, 190.0f, Z);
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
	private bool AmIHitter(FVector Landing)
	{
		if (Teammate == nullptr) return true;

		// A PLAYER SLIDING OUT A DIVE IS NOT AVAILABLE, and this has to be asked
		// first — before the touch-ownership rules below, which would otherwise
		// hand the job to a body lying face down on the sand. It is asked about
		// BOTH players on purpose: if the ball is only my teammate's because they
		// are nearer, and they are mid-slide, then it is mine and nobody had been
		// claiming it.
		if (bRagdollActive)           { bWasHitter = false; return false; }
		if (Teammate.bRagdollActive)  { bWasHitter = true;  return true;  }

		// I never take two contacts in a row — if I made the last touch, it's
		// my teammate's turn now. This guarantees digger != setter != attacker.
		if (bIMadeLastTouch)          { bWasHitter = false; return false; }
		if (Teammate.bIMadeLastTouch) { bWasHitter = true;  return true;  }

		// Fresh ball coming over (no team touches yet): closest player digs,
		// with the back player favored for deep balls (typical serve receive).
		float MyDist    = (GetActorLocation() - Landing).Size2D();
		float TheirDist = (Teammate.GetActorLocation() - Landing).Size2D();

		// SERVE RECEIVE IS SPLIT LEFT/RIGHT, NOT FRONT/BACK.
		//
		// This used to be an unconditional DEPTH gate: any deep ball went to the
		// back player and the front player returned false no matter where either
		// stood. Serves land at |X| 500-600 against IsDeep's 350 threshold, so
		// every single serve counted as deep and the FRONT PLAYER NEVER TOOK ONE.
		//
		// Fixing it with a distance bias does not work either, and the measured
		// reason is worth recording: the back player's home (±560, +120) sits
		// almost exactly where serves land, so they are genuinely nearest nearly
		// every time and ANY back-favouring bias reproduces "never". The split
		// has to come from court ownership, not proximity.
		//
		// The codebase already has that ownership and it is the right one for a
		// two-player receive — MyHalfPinY gives Front the -Y half and Back the
		// +Y half. A serve landing clearly in a player's own half is theirs,
		// which is exactly how a real beach pair splits serve receive. Only the
		// narrow band down the middle falls through to distance.
		bool bDeep = IsDeep(Landing.X);
		bool bMine;
		bool bFrontOwnsIt = (Landing.Y < -HalfClaimY);
		bool bBackOwnsIt  = (Landing.Y >  HalfClaimY);
		// ...unless the owner is hopelessly out of position. Measured case: a
		// serve to Y=-213 is the front player's by half, but they were 685cm away
		// while the back player stood 112cm from it. Owning a half is not worth a
		// cross-court sprint past a teammate who is already there.
		bool bOwnerStranded = (MyDist - TheirDist) > HalfOverrideDist;
		bool bPartnerStranded = (TheirDist - MyDist) > HalfOverrideDist;
		if (bDeep && (bFrontOwnsIt || bBackOwnsIt) && !bOwnerStranded && !bPartnerStranded)
		{
			bMine = (Role == EPlayerRole::Role_Front) ? bFrontOwnsIt : bBackOwnsIt;
		}
		else
		{
			// STICKY ROLE: with a bare closest-player rule, two nearly equidistant
			// teammates swapped hitter/support every AI tick and both shuttled
			// between two goals. The incumbent keeps the ball unless the partner
			// is CLEARLY closer.
			//
			// The margin comes from the PAIR's state, not from my own flag, and
			// that is what makes this decision have exactly one winner. It used
			// to be `bWasHitter ? +60 : -60`, evaluated independently by both
			// players with the SAME sign — so at the start of every rally, when
			// both flags are false, both used -60 and each claimed only if it was
			// 60cm closer than the other. Any ball landing between them, with the
			// two within 60cm of equal distance, was claimed by NEITHER and
			// simply dropped. (Both flags true inverted it: both claimed and both
			// chased.) With the support state now gone, "neither claims" means
			// both walk to base and watch the ball land.
			//
			// Reading both flags makes the comparison antisymmetric: whoever
			// holds the claim gets +60, the other gets -60, and if nobody holds
			// it both get 0 and pure distance decides. One of the two conditions
			// is always true and never both.
			bool bIHoldIt = bWasHitter && !Teammate.bWasHitter;
			bool bTheyHoldIt = Teammate.bWasHitter && !bWasHitter;
			float Margin = bIHoldIt ? 60.0f : (bTheyHoldIt ? -60.0f : 0.0f);
			// Exact ties still need a winner, and a coin flip would alternate.
			// Role is stable and opposite for the two players, so it decides once
			// and identically on both sides.
			bMine = (MyDist != TheirDist)
				? (MyDist <= TheirDist + Margin)
				: (Role == EPlayerRole::Role_Back);
		}

		// One line per player per deep receive, so who takes it can be COUNTED
		// from the log instead of watched. Emitted once per dead-ball cycle
		// (bServeRecvLogged resets with every other per-rally flag) — without
		// that guard this fires every AI tick for the whole approach.
		if (bDeep && !bServeRecvLogged)
		{
			bServeRecvLogged = true;
			Log("SERVERECV " + DebugTag() + " " + GetName()
				+ " mine=" + (bMine ? 1 : 0)
				+ " landX=" + int(Landing.X) + " landY=" + int(Landing.Y)
				+ " myDist=" + int(MyDist) + " theirDist=" + int(TheirDist));
		}

		bWasHitter = bMine;
		return bWasHitter;
	}

	// Dead band (cm) either side of the centre line where neither player owns the
	// serve by half and distance decides instead. Wide enough that a ball down
	// the middle is not awarded on a centimetre, narrow enough that the halves
	// still do the work. Verified by counting SERVERECV lines, not by eye.
	const float HalfClaimY = 80.0f;

	// How much farther than the partner the half-owner may be before ownership is
	// abandoned and the closer player simply takes it. Comfortably above the
	// normal in-formation gap (measured 40-115cm on receives the halves should
	// decide) so it only fires on genuinely stranded cases.
	const float HalfOverrideDist = 250.0f;

	// One SERVERECV line per dead-ball-to-contact cycle; reset on every dead ball.
	private bool bServeRecvLogged = false;
	// One RECVPLAN line per ball, reset with the other per-rally flags.
	private bool bRecvPlanLogged = false;

	// Hysteresis state for AmIHitter (who owns the current ball).
	private bool bWasHitter = false;

	// Attack-on-two decision, made once per second ball (see PlayHitter).
	private bool bOnTwoDecided = false;
	private bool bChoseOnTwo = false;

	// Sticky set-vs-bump intention for the second touch (hysteresis ±0.15s
	// of slack — see PlayHitter).
	private bool bIntendSet = false;
	private bool bOnTwoLoggedNotViable = false;
	private int SetIntentLogs = 0;

	// Hysteresis state for the hitter's plant (see PlayHitter).
	private bool bHitterPlanted = false;
	// The facing snapshot taken on the frame the hitter plants, held until the
	// plant releases. See RequestBallFacing.
	private FVector PlantedFacing = FVector::ZeroVector;

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

		// ATTACK ON TWO: a perfect reception hangs through the strike zone, and
		// the second toucher then holds BOTH options — jump on it, or pass to
		// the partner — committing as late as the physics allow. Viability is
		// re-proven every tick against the jump budget; the moment it collapses
		// (ball dropped, plant unreachable) we fall through to the set below,
		// so the pass option stays open until just before contact. The choice
		// itself is made ONCE per ball (sticky — a flip-flopping intention is
		// exactly what the anti-flicker work exists to prevent).
		if (Touches == 1)
		{
			FVector Strike2;
			float Tau2 = PredictBallTimeToHeight(SpikeStrikeZ(), Strike2);
			bool bViable = false;
			if (Tau2 > 0.0f)
			{
				float TimeToApex2 = LoadedJumpVelocity / Math::Abs(Gravity);
				FVector Plant2 = ClampToCourt(FVector(Strike2.X + MySign() * 35.0f, Strike2.Y, 0));
				float Sprint2 = this.BodyTravelTime((GetActorLocation() - Plant2).Size2D());
				bViable = (Tau2 - (TimeToApex2 + JumpLoadDuration)) > Sprint2 - 0.10f;
			}
			if (!bOnTwoDecided && bViable)
			{
				bOnTwoDecided = true;
				// Surprise attack more often at higher difficulty; a blocked-in
				// lane would be checked here if blockers keyed on-2 (they key
				// the third ball, which is what makes this a surprise).
				bChoseOnTwo = Math::RandRange(0.0f, 1.0f) < 0.45f + 0.35f * Difficulty;
				Log("ONTWO decided chose=" + bChoseOnTwo + " tau=" + int(Tau2 * 100));
			}
			else if (!bOnTwoDecided && !bOnTwoLoggedNotViable)
			{
				// Not viable (yet): leave undecided so a rising ball can still
				// qualify, but log why ONCE for the telemetry greps.
				bOnTwoLoggedNotViable = true;
				Log("ONTWO notViable tau=" + int(Tau2 * 100));
			}
			if (bChoseOnTwo && bViable)
			{
				ApproachForSpike(DeltaTime);
				return;
			}
			if (bChoseOnTwo && !bViable)
				bChoseOnTwo = false;   // late fallback: play the pass instead
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
			// A fingerpass demands being comfortably UNDER the ball at forehead
			// height — in budget terms: that contact is playable with slack to
			// spare. The old check was a fixed radius; the budget knows better
			// (a slow floaty ball 3m away IS settable, a fast one 1m away isn't).
			// STICKY with hysteresis: re-deciding this from raw slack every AI
			// tick alternated Set(crouch .2)/Bump(crouch .5+) at the boundary —
			// a visible up-and-down bob while preparing the pass (which the
			// jitter monitor missed: the rise leg of the square wave stayed
			// under its rate threshold). Upgrade to Set only with real slack,
			// abandon it only when the budget has clearly failed.
			float ForeheadZ = GetActorLocation().Z + PlayerHeight * 0.9f;
			bool bPrevIntendSet = bIntendSet;
			float LogTau = 0.0f;
			if (bIntendSet)
			{
				// RETENTION: already committed — stay Set as long as the ball
				// still physically crosses forehead height ahead of us. No
				// re-litigating the travel budget against the spot we're
				// already standing at (see BallStillCrossesHeight).
				bIntendSet = this.BallStillCrossesHeight(ForeheadZ, LogTau);
			}
			else
			{
				// DECISION: full time budget before COMMITTING to a fingerpass.
				FInterceptPlan SetPlan = this.PlanIntercept(ForeheadZ, ForeheadZ);
				bIntendSet = SetPlan.bReachable && SetPlan.Slack >= 0.15f;
				LogTau = SetPlan.BallTime;
			}
			Intend = bIntendSet ? EHitType::Hit_Set : EHitType::Hit_Bump;
			if (SetIntentLogs < 50 && (bPrevIntendSet != bIntendSet || SetIntentLogs < 30))
			{
				SetIntentLogs++;
				Log("SETINTENT tau=" + int(LogTau * 100) + " intendSet=" + bIntendSet
					+ " wasSet=" + bPrevIntendSet);
			}
		}

		// Aim where we want to send it (sets the bounce direction for contact).
		// The reception pops to the setter zone; the SECOND ball is always
		// PLACED at the pin (see DoSet) no matter which stroke plays it.
		if (Touches == 0) DoDig();
		else              DoSet();

		// ONE budget decides everything below (MotionPlan.as): the highest
		// playable contact given ball time vs body time vs hand time, the
		// exact run speed the budget demands, when the reach must start, and
		// whether the ball is only reachable by diving.
		FInterceptPlan Plan = this.PlanIntercept(ContactHeightFor(Intend), FloorZ + 112.0f);

		// WHY DID THE RECEIVE FAIL? Roughly half of all rallies end with the
		// serve landing untouched (measured: seq=[ ] with crossings=1), and the
		// receiver is typically standing 66-77cm from where it lands — so it is
		// not a distance problem. One line per ball while this is being chased.
		// Gated on the ball being CLOSE (tau < 0.7s), not on the first tick of
		// the rally. The first version logged whichever plan happened to exist
		// when the ball had only just launched and was still 10m away, which
		// reports a contact point the receiver was never expected to be near
		// yet — dist=554 for a player who ends up 35cm from the landing spot.
		// The last moment before contact is the one that decides the outcome.
		if (Touches == 0 && !bRecvPlanLogged && Plan.BallTime < 0.7f)
		{
			bRecvPlanLogged = true;
			Log("RECVPLAN " + DebugTag()
				+ " reach=" + (Plan.bReachable ? 1 : 0)
				+ " dive=" + (Plan.bDive ? 1 : 0)
				+ " tau=" + int(Plan.BallTime * 100)
				+ " bodyT=" + int(Plan.BodyTime * 100)
				+ " handT=" + int(Plan.HandTime * 100)
				+ " slack=" + int(Plan.Slack * 100)
				+ " dist=" + int((Plan.Contact - GetActorLocation()).Size2D()));
		}

		// Desperate ball: nothing playable on foot but the dive window is open.
		if (Plan.bDive && CanDive())
		{
			StartDive(Plan.Contact - GetActorLocation());
			if (bDebugAI) Log(DebugTag() + " DIVE tau=" + int(Plan.BallTime * 100)
				+ " bodyT=" + int(Plan.BodyTime * 100));
		}
		if (IsDiving())
		{
			// The dive owns movement and facing; just keep the platform out.
			Reach(EHitType::Hit_Bump, Plan.Contact);
			return;
		}

		// PLAN vs ACTUAL: record the FIRST promise the budget made for this
		// contact (later ticks re-plan with shrinking τ and always converge to
		// slack≈0 — the informative number is what was booked at commitment).
		if (PlanSlackLog < 0.0f)
		{
			PlanSlackLog = Plan.Slack;
			PlanSpeedFracLog = Plan.SpeedFraction;
			// Compensation, the planner's half: a booking whose travel budget
			// does not fit the ball's flight is a promise the legs cannot keep,
			// and something downstream will have to cover it.
			MonPlanBookings += 1;
			if (Plan.BodyTime > Plan.BallTime) MonPlanInfeasible += 1;
			bBookedInfeasible = Plan.BodyTime > Plan.BallTime;   // DIAG
		}

		// STAGING IS GONE, and the comment it replaced was the tell: it claimed
		// "τ only shrinks, so stage → go crosses exactly once — no flicker."
		// That was false. BodyT is computed from the player's CURRENT distance to
		// the contact, and the staging decision itself moves the player: stage
		// sends them to the pin (farther) → BodyT grows → un-stage → run at the
		// ball (closer) → BodyT shrinks → stage again. A positive feedback loop
		// with a switching boundary around 288cm from the contact, ticking at the
		// ~9Hz AI rate. That is the vibration, and it was worst exactly where it
		// was reported: a player waiting to dig or set.
		//
		// Nothing replaces it. A player whose ball it is walks to the contact and
		// waits there; a player with time to spare simply arrives early, which is
		// what MoveToHold's hold was always for.

		// Stand where the plan meets the ball — MINUS a standoff along the
		// flight chord, so the contact happens IN FRONT of the chest where the
		// platform/cup is, never on top of the head. (Chord, not live velocity:
		// the live velocity swings during the rally and churned the goal.)
		FVector PlaySpot = Plan.Contact;
		FVector Chord = FVector(PlaySpot.X - Ball.Position.X, PlaySpot.Y - Ball.Position.Y, 0);
		FVector Vel2D = FVector(Ball.BallVel.X, Ball.BallVel.Y, 0);
		// 15cm, not 35: the FBIK root pre-pull used to close the last stretch by
		// dragging the whole body ~26cm at the ball, which is also what made the
		// hip bounce (see IK_Mannequin's PrePull Z, now off). With the solver no
		// longer allowed to cheat the distance, the FEET have to cover it, so the
		// digger stands where the contact actually is. Measured over three runs
		// each: 2.85 contacts per rally at 35cm against 3.04 at 15cm, back inside
		// the 3.00-3.87 spread of unmodified runs.
		// 30, not 45: a bigger standoff is MORE rule-1 compliant on its own
		// (ballFwd median +24 vs +10, 15% behind vs 18%) but measurably starves
		// the attack — 11/11/11 attacks per run against 14-19 at 30, no overlap.
		// Standing that far back changes where the second ball is struck from
		// and the pass stops arriving attackable. 30 buys almost all of the
		// rule-1 gain and none of that cost.
		float Standoff = (Intend == EHitType::Hit_Set) ? 30.0f : 15.0f;
		FVector Back = (Chord.SizeSquared() > 400.0f && Vel2D.DotProduct(Chord) > 0.0f)
			? Chord.GetSafeNormal()
			: FVector::ZeroVector;
		if (Back.SizeSquared() < 0.01f)
		{
			// A BALL DROPPING STRAIGHT DOWN STILL HAS TO BE IN FRONT OF US
			// (rule 1). There is no flight chord to stand back along here — the
			// dig pops up almost vertically and comes down the same line — and
			// the old code answered that by applying NO standoff at all, which
			// parks the setter exactly underneath the ball. Measured: the second
			// touch met the ball 5cm BEHIND the chest (median) and 61cm above
			// the actor centre, i.e. below the 74cm forehead threshold, so not
			// one second ball in three runs classified as a set — they were all
			// baggers taken off the top of the head.
			//
			// What a setter actually does under a vertical ball is square up to
			// the target and let it drop in front of the brow, so the standoff
			// direction is the AIM: stand back from the contact along the line
			// to where we are sending it, and the ball is between us and the
			// target. That also agrees with the facing, since FaceBall then
			// looks the same way — which is why this reads as +standoff in the
			// PLANVA ballFwd column rather than needing its own facing rule.
			FVector ToAim = FVector(DesiredAim.X - PlaySpot.X, DesiredAim.Y - PlaySpot.Y, 0);
			if (bHasAim && ToAim.SizeSquared() > 400.0f)
				Back = -ToAim.GetSafeNormal();
		}
		FVector Goal = ClampToCourt(FVector(PlaySpot.X, PlaySpot.Y, 0) + Back * Standoff);
		float DistToGoal = (GetActorLocation() - Goal).Size2D();

		// Plant state with HYSTERESIS: the goal recomputes every tick with a
		// few cm of prediction noise, and a bare radius check flip-flopped
		// planted <-> running at tick rate — the crouch request alternated
		// with it and the knees vibrated (the jitter monitor's residual
		// crouchFlips after the chest-feedback fix).
		if (bHitterPlanted)
		{
			if (DistToGoal > PlantRadius + 35.0f) bHitterPlanted = false;
		}
		else if (DistToGoal <= PlantRadius)
			bHitterPlanted = true;

		if (!bHitterPlanted)
			MoveToward2D(Goal, DeltaTime, false, Plan.SpeedFraction);
		else
		{
			MovePlayer(FVector2D::ZeroVector);
			// Planted and waiting: LOW base. A bagger wants the centre of mass
			// down (legs set the height; the arms just hold their slope).
			RequestCrouch(Intend == EHitType::Hit_Bump ? 0.45f : 0.25f);
		}

		// Ball-face only once we're ON the dig/set spot (or nearly there). Asking
		// for it during the whole approach kept chest-to-ball while travel ran
		// toward a receive spot behind the player — turn-and-run cleaned some of
		// that up, but every sprint still spent a beat bent-forward backpedaling
		// before the body caught the travel yaw. Head LookAt still tracks the
		// ball every frame; square-up happens in the last ~1.5m / when planted.
		if (bHitterPlanted || DistToGoal < 150.0f)
			FaceBall();

		// Wind up on the last stretch only. Reach-while-sprinting handed FBIK
		// a platform target in front of a running torso and the solver folded
		// the spine to meet it — the "böjer sig framåt" silhouette on every
		// approach. Late balls still get AutoReach at arm's length.
		if (Plan.bStartGesture && (bHitterPlanted || DistToGoal < 160.0f))
			Reach(Intend, Plan.Contact);
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
		// NOT routed through Predict::BallTimeToHeight, and that is a measured
		// decision rather than an oversight. This returns the first sample PAST
		// the crossing; the shared helper interpolates, which is strictly more
		// accurate — and swapping it in cost contacts per rally 2.88-3.17 ->
		// 2.42-2.73 with builds 100% -> 85-95%, ranges not overlapping over
		// three runs each. The jump and dive timing downstream is calibrated
		// against this being one step late. Fixing it means retuning them; do
		// the pair or neither.
		FVector P = Ball.Position;
		FVector V = Ball.BallVel;
		const float G = -980.0f;
		const float Dt = 0.02f;
		float T = 0.0f;
		while (T < 3.0f)
		{
			V.Z += G * Dt;
			FVector Next = P + V * Dt;
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
		RequestBallFacing();
	}

	// A BEARING COMPUTED FROM A SHRINKING VECTOR IS NOT A DIRECTION.
	//
	// This one line was the shake reported as "de vibrerar mellan två positioner,
	// innan varje mottag". The old guard was SizeSquared() > 1.0f — one square
	// CENTIMETRE — so a ball 2cm from the player's vertical axis still produced a
	// facing target, and that target's angular rate goes as v/r: at r = 10cm a
	// ball crossing at 400 cm/s sweeps the bearing at 2300 deg/s. The body chases
	// it through three cascaded rate limiters (SmFacingDir 300, SmWantDir 300,
	// the body 450 deg/s), and cascaded lags chasing a target that sweeps faster
	// than they can follow is the textbook recipe for a limit cycle. Measured on
	// the live run: yaw reversing at +-60 to +-110 deg/s with speed=0, moveIn=0,
	// hit set — a planted player rocking in place.
	//
	// It happens BEFORE EVERY RECEIVE by construction: the receiver plants at the
	// contact point (standoff 35cm, and zero on a vertical drop) and the ball
	// then descends onto exactly that spot, so r goes to zero every single time.
	//
	// Every position-based detector is blind to it because the FEET NEVER MOVE:
	// wasteWorst stays at 100 (a perfectly straight path of length zero) while
	// the whole body rocks. See MonYawRevisit below for the fix to that.
	//
	// The repair is not more smoothing — smoothing a target that sweeps through
	// 180 deg only converts a snap into a sustained rock, which is precisely what
	// the previous pass did. Inside FaceNearRadius the ball is no longer
	// something to LOOK AT, it is something ARRIVING: face where it is coming
	// FROM. The flight chord is stable all the way to contact, and squaring up to
	// the incoming ball is also what a real player does on a dig.
	// A WORLD-space direction toward the ball, computed so it never produces
	// the degenerate high-angular-rate sweep a raw bearing gets as the player
	// closes on it (rate goes as v/r — blows up as r->0; the ORIGINAL "de
	// vibrerar" bug, see the long comment that used to sit here and now sits
	// on RequestBallFacing below).
	//
	// Returns FVector::ZeroVector to mean "no new bearing — hold whatever
	// facing is already active": either I just hit this ball myself (BallVel
	// is now MY outgoing swing, not something arriving, and chasing its
	// reversal is the same bug with a different trigger — see
	// RequestBallFacing), or a near-vertical drop has no horizontal bearing
	// at all. Every caller must treat a zero result as "hold", not "face
	// world +X" — GetSafeNormal of a zero vector IS FVector(1,0,0), so
	// skipping the zero-check silently reintroduces a degenerate direction
	// instead of holding.
	private FVector StableBallBearing() const
	{
		FVector To = Ball.Position - GetActorLocation();
		To.Z = 0.0f;

		// Above this radius the bearing is well conditioned: at 150cm even a
		// 900 cm/s crossing ball sweeps it at 344 deg/s, which the body can
		// track without lagging into oscillation.
		const float FaceNearRadius = 150.0f;
		if (To.SizeSquared() > FaceNearRadius * FaceNearRadius)
			return To.GetSafeNormal();

		if (bIMadeLastTouch)
			return FVector::ZeroVector;

		// Close in: face the ball's approach instead of its position.
		//
		// THE CHORD IS A LINE, NOT A RAY. -BallVel means "where it came from"
		// only while the ball is still closing; on a ball that has already
		// passed the plant spot, or one crossing tangentially, it points the
		// opposite way to the bearing this same function returned one frame
		// earlier on the far side of FaceNearRadius. And that crossing happens
		// before EVERY dig by construction — the receiver plants on the
		// contact point and the ball descends onto it, so |To| falls through
		// 150cm every single time. MEASURED on a 165s match: 91 single-frame
		// reversals of the facing request, 63 of them past 150°, 54 with the
		// intent already set to Hit_Bump and 26 with the feet completely
		// still. The body then spent ~0.45s grinding through the flip at the
		// 300°/s target limiter and turned straight back when the run
		// resumed: out, back, out — "de skakar innan varje bagger".
		//
		// Both signs describe the same flight line, so pick the one that
		// agrees with where the body is already aimed. At the handover frame
		// that is the well-conditioned bearing TO the ball, so the receiver
		// still squares up to the incoming ball — it just never gets told to
		// spin 180° to do it.
		FVector From = FVector(-Ball.BallVel.X, -Ball.BallVel.Y, 0.0f);
		if (From.SizeSquared() > 100.0f * 100.0f)   // 100 cm/s of usable horizontal flight
		{
			FVector Chord = From.GetSafeNormal();
			if (FacingDir.SizeSquared() > 0.01f)
			{
				FVector Aimed = FVector(FacingDir.X, FacingDir.Y, 0.0f).GetSafeNormal();
				if (Chord.DotProduct(Aimed) < 0.0f)
					Chord = -Chord;
			}
			return Chord;
		}
		return FVector::ZeroVector;
	}

	// This one line was the shake reported as "de vibrerar mellan två positioner,
	// innan varje mottag". The old guard was SizeSquared() > 1.0f — one square
	// CENTIMETRE — so a ball 2cm from the player's vertical axis still produced a
	// facing target, and that target's angular rate goes as v/r: at r = 10cm a
	// ball crossing at 400 cm/s sweeps the bearing at 2300 deg/s. The body chases
	// it through three cascaded rate limiters (SmFacingDir 300, SmWantDir 300,
	// the body 450 deg/s), and cascaded lags chasing a target that sweeps faster
	// than they can follow is the textbook recipe for a limit cycle.
	//
	// This same degenerate bearing was independently duplicated at the spike
	// approach's 22°-open-shoulder call site (raw To.GetSafeNormal() gated on
	// SizeSquared() > 1.0f, unfixed) — found by tracing a live yaw sweep back
	// to its source and discovering it wasn't THIS function at all. Fixed by
	// having both call StableBallBearing() above instead of each computing
	// their own bearing.
	private void RequestBallFacing()
	{
		// A PLANTED RECEIVER SQUARES UP ONCE AND HOLDS IT.
		//
		// Everything above makes the BEARING well conditioned; none of it makes
		// the bearing CONSTANT, and the body is asked to re-aim at it every
		// frame through a 300°/s target limiter. Measured on a planted, deeply
		// crouched digger with the feet stationary for a full second: the
		// request stepped 174° in one frame and the body ground 120° across the
		// floor chasing it, then turned back when the run resumed. Any bearing
		// that steps while the feet are still buys a half-second in-place spin,
		// and the steps come in pairs — that is the shake before every bump.
		//
		// So stop re-solving it. The instant the hitter plants, take the
		// bearing once and hold that snapshot until the plant releases (the
		// goal moved out of PlantRadius + 35, or the rally ended). One turn per
		// approach, no re-evaluation, nothing left to oscillate between. It is
		// also what a real receiver does: square up on arrival and stay there.
		// The eyes keep following the ball — the look target is a separate
		// channel and is untouched by this.
		if (bHitterPlanted && PlantedFacing.SizeSquared() > 0.01f)
		{
			FacingDir = PlantedFacing;
			bHasFacing = true;
			return;
		}

		FVector Dir = StableBallBearing();
		if (Dir.SizeSquared() > 0.01f)
			FacingDir = Dir;
		if (bHitterPlanted)
			PlantedFacing = FacingDir;
		// else: hold the last direction — still asserting bHasFacing so the
		// request does not lapse into velocity-facing, which would hand the
		// body a fresh target and restart the very oscillation this exists to
		// prevent.
		bHasFacing = true;
	}


	// Turn to face whichever teammate/opponent is about to attack (or the ball), so
	// we're oriented into the play while standing still.
	private void FaceAttacker()
	{
		// Same single-authority facing request, and the same degenerate-bearing
		// guard — a blocker at the net has the ball come at them too.
		RequestBallFacing();
	}

	// Minimum desired distance between teammates: about half the court width, so an
	// attacker always has a spike option AND a clearly separated pass option.
	const float MinSeparation = 450.0f;   // ~half of the 900cm-wide court


	// ---------------------------------------------------------------
	// Spike approach — world-class shape: wait loaded at an approach start point
	// BEHIND the predicted strike spot, then a committed sprint through the
	// plant, jumping so the apex coincides with the ball arriving at strike
	// height. Momentum now carries through the jump (no air steering), which is
	// exactly how a real approach converts run speed into attack reach.
	// ---------------------------------------------------------------
	// Contact height for the jump attack: with the loaded jump (~115cm rise at
	// the heavy player gravity) the hands top out ~355cm at apex — strike
	// where the descending ball is slow and still inside that envelope. These
	// are real beach volleyball numbers (net 243, contact ~350).
	// Strike height DERIVED from jump physics: actor base + the loaded jump's
	// ballistic rise (v²/2g) + the rig's raised-hand reach above the actor
	// centre (the one measured constant). Retuning jump speed or gravity
	// re-derives the strike zone automatically instead of stranding a magic
	// 350 that silently stops matching the body.
	//
	// The reach was 123, which put STANDING reach at 90 + 123 = 213cm — about
	// 25cm short for an elite player — and the shortfall was being paid for by
	// a 115cm jump, half again the world-class 60-90. The BIOMECH line caught
	// the jump; the short arms were what it was compensating for. Splitting it
	// the anatomically honest way (240cm standing reach, 90cm jump) lands the
	// contact at the same height, so the strike zone and every timing budget
	// built on it are unchanged. (Sanity: 90 + 90 + 150 = 330; net is 243 and
	// real elite contact is 330-350.)
	const float StrikeReachAboveCenter = 150.0f;
	float SpikeStrikeZ() const
	{
		float Rise = (LoadedJumpVelocity * LoadedJumpVelocity) / (2.0f * Math::Abs(Gravity));
		return FloorZ + PlayerHeight + Rise + StrikeReachAboveCenter;
	}
	const float ApproachBack = 200.0f;  // run-up starts this far behind the plant
	// How far our side of the strike point the hitter stands, so the ball is in
	// FRONT of the hitting shoulder at contact rather than on top of the head.
	const float SpikeBallAhead = 60.0f;

	private void ApproachForSpike(float DeltaTime)
	{
		float TimeToApex = LoadedJumpVelocity / Math::Abs(Gravity);   // ≈ 0.35s (loaded jump)

		FVector Strike;
		float Tau = PredictBallTimeToHeight(SpikeStrikeZ(), Strike);

		if (Tau < 0.0f)
		{
			// The set never gets to strike height — no jump attack available. Get
			// under where it drops to play height and hit it over instead.
			FVector PlaySpot = PredictBallAtHeight(ContactHeight());
			MoveToward2D(ClampToCourt(FVector(PlaySpot.X, PlaySpot.Y, 0)), DeltaTime);
			FaceBall();
			DoSpike();   // still aim into the opponent court
			if ((GetActorLocation() - Ball.Position).Size() < PrepareDistance)
				Reach(EHitType::Hit_Bump, PlaySpot);
			return;
		}

		// Plant just our-side of the strike point so contact happens in front of
		// the hitting shoulder, not on top of the head.
		// RULE 1 FOR THE ATTACK. The body's place is a stride OUR SIDE of the
		// strike point so the ball arrives in front of the hitting shoulder,
		// which is where the swing's strike pose puts the hand (PlayerIK builds
		// it at ShR + Fwd*24 above the shoulder). 35cm was less than that reach,
		// i.e. the stance itself already asked for a contact behind the hand.
		FVector Plant = ClampToCourt(FVector(Strike.X + MySign() * SpikeBallAhead, Strike.Y, 0));
		float DistToPlant = (GetActorLocation() - Plant).Size2D();
		// Same body-time model as the intercept budget (accel-limited + lag).
		float SprintTime = this.BodyTravelTime(DistToPlant);

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
				// Was a raw To.GetSafeNormal() gated on SizeSquared() > 1.0f — the
				// same degenerate-bearing bug StableBallBearing() exists to kill
				// (see its comment), duplicated here rather than shared, and the
				// worst place for it to hide: this runs during the committed
				// sprint into the plant, exactly the highest-speed, smallest-r
				// combination the bug needs.
				FVector N = StableBallBearing();
				if (N.SizeSquared() > 0.01f)
				{
					const float OpenRad = -22.0f * PI / 180.0f;
					float C = Math::Cos(OpenRad);
					float Sn = Math::Sin(OpenRad);
					FacingDir = FVector(N.X * C - N.Y * Sn, N.X * Sn + N.Y * C, 0);
				}
				bHasFacing = true;
				// Leave the ground one apex-time before the ball reaches the strike
				// height; stop driving so the jump converts momentum, not input.
				// MARGIN BIAS MATTERS: an EARLY jump tops out while the ball is
				// still above the hands (a guaranteed whiff — stats2: 13 jumps, 0
				// contacts at +0.18); a LATE jump meets the ball a touch lower but
				// still inside the envelope. Keep the margin tiny so AI tick
				// jitter lands on the late (reachable) side.
				// The gather (JumpLoadDuration) happens BEFORE takeoff, so the
				// decision fires one load earlier. StartLoadedJump does the
				// plant (momentum brake — full-speed jumps drifted 3-4m past
				// the strike point) and the deep full-body sink.
				// Window sized to the decision cadence (this gate is examined
				// every ReactionDelay) but capped LATE-biased: an early jump
				// tops out above the ball and whiffs, a late one still meets
				// it inside the envelope (stats2 autopsy).
				float JumpEps = Math::Clamp(ReactionDelay * 0.4f, 0.02f, 0.05f);
				// THE JUMP CARRIES THE BODY, so "am I at the plant" is the wrong
				// question — the right one is "will I be at the plant when the
				// ball gets to strike height". The gather bleeds the run to
				// JumpLoadSpeedKeep across JumpLoadDuration and the ascent then
				// flies that residue for a whole TimeToApex, which at approach
				// speed is most of a stride of travel AFTER the decision. A
				// hitter who waits until they REACH the plant therefore contacts
				// the ball past it, with the ball behind the shoulder — rule 1,
				// and the reported "armen bakom sig". Predicting the carry also
				// fires the jump slightly EARLIER on a fast approach, which is
				// the side the strike height wants: a late jump tops out after
				// the ball has fallen out of the envelope.
				float CarryTime = JumpLoadDuration * 0.5f * (1.0f + JumpLoadSpeedKeep)
					+ TimeToApex * JumpLoadSpeedKeep;
				FVector AtStrike = GetActorLocation()
					+ FVector(PlayerVelocity.X, PlayerVelocity.Y, 0.0f) * CarryTime;
				float PlantMiss = (AtStrike - Plant).Size2D();
				// The distance term stays as a floor for the standing case: a
				// hitter already parked on the plant has no carry to predict and
				// must still be allowed to jump.
				if ((PlantMiss < 70.0f || DistToPlant < 45.0f)
					&& Tau <= TimeToApex + JumpLoadDuration + JumpEps)
				{
					MovePlayer(FVector2D::ZeroVector);
					StartLoadedJump();
					if (bDebugAI && IsJumpLoading()) Log(DebugTag() + " SPIKE JUMP tau=" + int(Tau * 100) + " dist=" + int(DistToPlant));
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
			Reach(EHitType::Hit_Spike, Ball.Position);
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

	// PLACEMENT RULE (Erik): every pass goes to one metre inside the antenna
	// on the PARTNER's half, and every player EXPECTS passes at the pin on
	// their OWN half. The halves are static per role (Front owns -Y, Back
	// owns +Y — matching HomePosition), which closes the system: the left
	// player receives toward the right pin where the partner already waits,
	// that partner plays the second ball there and passes back to the left
	// pin where the receiver-turned-attacker is loading their approach.
	// Nobody ball-chases; everyone anticipates.
	private float MyHalfPinY() const
	{
		float HalfMax = (Role == EPlayerRole::Role_Front) ? CourtMinY : CourtMaxY;
		return (HalfMax < 0.0f) ? HalfMax + 100.0f : HalfMax - 100.0f;
	}

	private FVector PartnerPinTarget() const
	{
		// Aim point = the FLOOR at the partner's pin: the ballistic target is
		// where the arc comes DOWN, so an air target let an unattacked pass
		// sail on and land ~2m out of court. Grounding it keeps the ball in
		// play if nobody touches it; the partner intercepts the same arc at
		// their contact height on its way down.
		float PartnerHalfMax = (Role == EPlayerRole::Role_Front) ? CourtMaxY : CourtMinY;
		float AimY = (PartnerHalfMax < 0.0f) ? PartnerHalfMax + 100.0f : PartnerHalfMax - 100.0f;
		// 1m off the net (Erik): 50cm landed sets too close, some overshooting
		// the net line entirely under aim error (AimErrCm in OnBallContact).
		return FVector(MySign() * 100.0f, AimY, 20.0f);
	}

	// Where I WAIT for the pass I'm expecting: the approach start behind my
	// own-half pin, ready to run in and attack or set whatever arrives.
	protected FVector MyPinApproachStart() const
	{
		return ClampToCourt(FVector(
			MySign() * (100.0f + ApproachBack), MyHalfPinY(), FloorZ + PlayerHeight));
	}

	private FVector PassTarget() const
	{
		float PartnerHalfMax = (Role == EPlayerRole::Role_Front) ? CourtMaxY : CourtMinY;
		float AimY = (PartnerHalfMax < 0.0f) ? -120.0f : 120.0f;
		return FVector(MySign() * 180.0f, AimY, 20.0f);
	}

	private void DoDig()
	{
		AimAt(PassTarget());
	}

	private void DoSet()
	{
		AimAt(PartnerPinTarget());
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
	// Defense: the ball is on the opponent's side. Two defenders split the court
	// (one covers each Y half) UNLESS it's a clear jump-spike threat at the net —
	// then the front player blocks at the net and the back player covers the line
	// behind the block.
	// ---------------------------------------------------------------
	// BLOCK: hold the net while the opponent attacks. Extracted from the old
	// PlayDefense, which also owned the deep-defender and no-cue-return cases —
	// both of those are just "no job", i.e. Base, so they are gone. What remains
	// here is the one genuinely distinct position: front player at the net.
	//
	// Entry and exit are the STATE's job now (StateMinDwell), not this
	// function's. bSpikeCueOn used to be able to move the goal 2.7m the instant
	// its raw OR flipped, which is precisely the class of teleport the state
	// commit exists to absorb.
	private void PlayBlock(float DeltaTime)
	{
		float NetX = MySign() * 55.0f;   // right up at the net on our side

		// Aim the block at the middle of the opponent's court so a stuffed ball
		// drops there (DesiredAim drives the hand angle in UpdateIKTargets).
		AimAt(FVector(-MySign() * 300.0f, 0.0f, FloorZ));

		bool bSpikeIncoming = UpdateSpikeIncoming(FindAttackingOpponent());
		// Hold the middle of the net while the opponent is still building. Track
		// laterally only after the attack cue; following every set's small Y
		// drift was visually busy and gave up the centre for no benefit.
		float BlockY = bSpikeIncoming
			? Math::Clamp(Ball.Position.Y, CourtMinY + 60.0f, CourtMaxY - 60.0f)
			: BasePosition().Y;
		FVector Goal = FVector(NetX, BlockY, FloorZ + PlayerHeight);

		if (!bIsGrounded)
		{
			// Airborne: hold still (no drift) and throw up the block NOW.
			MovePlayer(FVector2D::ZeroVector);
			Reach(EHitType::Hit_Block, Ball.Position);
			return;
		}

		float Horiz = (GetActorLocation() - FVector(Goal.X, Goal.Y, 0)).Size2D();
		if (bSpikeIncoming && Horiz < 90.0f)
		{
			// Kill the drive FIRST so the block jump is vertical — momentum
			// carries in the air, and drifting into the net is a fault. Blocks
			// load too: the same full-body gather as the attacker.
			MovePlayer(FVector2D::ZeroVector);
			if (FVector(PlayerVelocity.X, PlayerVelocity.Y, 0).Size() < 90.0f)
				StartLoadedJump();
		}
		else
		{
			// Track the ball along the net in a loaded stance, hands low.
			MoveToHold(ClampToCourt(Goal), DeltaTime, 0.85f);
			RequestCrouch(0.3f);
		}
		if (bDebugAI) Log(DebugTag() + " BLOCK incoming=" + bSpikeIncoming);
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

		// We already own this touch (GS.LastTouchTeam == TeamSide via
		// TeamTouches() > 0): a normal dig aimed at PassTarget() (X=-180, well
		// inside our own court) MEASURED at X=+34, velX=-43 for over a second
		// right after contact — past X=0 from contact geometry near the net,
		// but short of BOTH bBallOnMySide's X<=0 and bMovingToMe's velX<-50
		// below, so this read as "not mine" for the whole crossing window and
		// silently killed the touch=1 (attacker/3rd-touch) anticipation branch
		// in PlayBase every time it was captured. A genuine one-touch-over hits
		// deep into the opponent's court (hundreds of cm), not a few dozen past
		// the net line, so this is safe to gate on distance rather than losing
		// the foul case this function's caller comment warns about.
		if (TeamTouches() > 0 && Math::Abs(Ball.Position.X) < 100.0f) return true;

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
	// --- Spike-incoming cue, with the same commit/release discipline every other
	// decision in here already has ------------------------------------------
	// This was a raw OR of three threshold tests, re-evaluated every AI tick. All
	// three inputs (attacker airborne, ball near net, ball descending fast) can
	// cross back and forth within one flight, and a single toggle moves the block
	// goal from the net centre out to the ball's Y — up to 2.7m. That is far past
	// MoveToHold's 110cm StartMoving, so the hold releases and the player runs,
	// then runs back. No existing detector saw it: the run itself is perfectly
	// smooth, so neither velocity nor yaw ever reverses. It shows up as goalJumps.
	//
	// Bands do not overlap, matching the block-commitment pattern below: commit on
	// the real cue, release only when the ball is clearly no longer an attack.
	private bool bSpikeCueOn = false;
	private bool UpdateSpikeIncoming(AAIPlayer Att)
	{
		bool bAttackerAirborne = (Att != nullptr && !Att.bIsGrounded);
		float BallX = Math::Abs(Ball.Position.X);
		float BallZ = Ball.Position.Z;

		if (!bSpikeCueOn)
		{
			// Commit: the attacker has left the ground with the ball at the net, or
			// the ball is already coming down hard.
			bool bNearNet = BallX < 350.0f && BallZ > 220.0f;
			if ((bAttackerAirborne && bNearNet) || (bNearNet && Ball.BallVel.Z < -250.0f))
				bSpikeCueOn = true;
		}
		else
		{
			// Release on a wider band, so the small drifts that flipped the raw
			// test cannot un-commit us mid-approach.
			if (BallX > 480.0f || BallZ < 150.0f)
				bSpikeCueOn = false;
		}
		return bSpikeCueOn;
	}

	private void MoveToward2D(FVector Target, float Dt, bool bSprint = false, float SpeedCap = 1.0f)
	{
		ReportMoveGoal(Target);
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
		// The split step is the anticipatory READ load — it belongs BEFORE the
		// approach, not on top of a committed contact. Once we're actively
		// reaching for this ball the reach/RequestCrouch stance owns the hips;
		// letting the dip's rise phase overlap the dig produced a fast up-down
		// bob right at the meet on quick balls (the read hadn't finished before
		// contact). Cancel it the moment we commit — a real player who has no
		// time to gather simply skips the hop.
		if (bReaching)
			SplitStepTimer = 0.0f;

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

		// Opponent contact: their touch team/count just changed. But a defender
		// split-steps ONCE, on the ATTACKER'S swing — not on every touch of their
		// possession. Firing on their receive AND set AND attack stacked three
		// dips in a row and read as the body shaking up and down before we ever
		// dug the ball. The attack is the touch that DRIVES THE BALL TOWARD US;
		// their own-side receive/set keep it on their court (X small or away), so
		// gate on the post-contact velocity heading to our side. The serve above
		// is the serve-phase equivalent of that same read.
		int Stamp = int(GS.LastTouchTeam) * 100 + GS.TouchesThisRally;
		if (Stamp != PrevTouchStamp)
		{
			bool bOpponentHit = GS.LastTouchTeam != TeamSide
				&& GS.LastTouchTeam != ETeam::Team_None && Ball.bInPlay;
			// Ball now driving to our side (their attack), not along their own.
			bool bDrivenAtUs = (TeamSide == ETeam::Team_A)
				? Ball.BallVel.X < -150.0f : Ball.BallVel.X > 150.0f;
			if (bOpponentHit && bDrivenAtUs)
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
		// Report here too, not just via MoveToward2D: while holding, a target that
		// teleports never reaches MoveToward2D at all until the hold breaks, and
		// that break is exactly the event worth counting.
		ReportMoveGoal(Target);
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
		return !bIMadeLastTouch && !bRagdollActive;
	}

	protected void FindBall()
	{
		TArray<AActor> Found;
		GetAllActorsOfClass(ABall, Found);
		if (Found.Num() > 0)
			Ball = Cast<ABall>(Found[0]);
	}
}
