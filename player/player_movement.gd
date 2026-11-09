extends CharacterBody3D

# ====== NODE REFERENCES ======
# Expected scene structure:
# CharacterBody3D (this script)
#   CollisionShape3D (capsule, resize this on crouch)
#   Head (Node3D) -- handles camera bob/tilt, child of body
#     Camera3D

@onready var head: Node3D = $head
@onready var camera: Camera3D = $head/Camera3D
@onready var collision_shape: CollisionShape3D = $CollisionShape3D

# ====== MOVEMENT TUNING ======
@export_group("Speeds")
@export var walk_speed: float = 5.0
@export var sprint_speed: float = 8.0
@export var crouch_speed: float = 2.5
@export var slide_speed: float = 11.0

@export_group("Acceleration")
@export var ground_accel: float = 14.0       # how fast you reach target speed
@export var ground_decel: float = 10.0       # how fast you stop (no input)
@export var air_accel: float = 4.0           # lower = more "weighty" air control
@export var air_decel: float = 1.5

@export_group("Jump & Gravity")
@export var jump_velocity: float = 4.8
@export var gravity_multiplier: float = 1.0
@export var coyote_time: float = 0.12        # grace period to jump after leaving ledge
@export var jump_buffer_time: float = 0.12   # grace period if jump pressed slightly early
@export var fall_gravity_multiplier: float = 1.6  # falling feels snappier than rising

@export_group("Crouch & Slide")
@export var standing_height: float = 1.8
@export var crouch_height: float = 1.0
@export var crouch_transition_speed: float = 10.0
@export var slide_duration: float = 0.65
@export var slide_friction: float = 3.0
@export var min_slide_speed_to_start: float = 3.0  # must be moving this fast to slide

@export_group("Camera Juice")
@export var bob_frequency: float = 2.4
@export var bob_amplitude: float = 0.045
@export var landing_dip_strength: float = 0.12
@export var landing_dip_recover_speed: float = 8.0
@export var tilt_amount_deg: float = 2.5
@export var fov_base: float = 75.0
@export var fov_sprint_add: float = 8.0
@export var fov_slide_add: float = 14.0
@export var fov_change_speed: float = 8.0

@export_group("Mouse Look")
@export var mouse_sensitivity: float = 0.0025
@export var max_look_up_deg: float = 89.0
@export var max_look_down_deg: float = -89.0

# ====== STATE ======
enum State { WALK, SPRINT, CROUCH, SLIDE, AIR }
var current_state: State = State.WALK

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

var coyote_timer: float = 0.0
var jump_buffer_timer: float = 0.0
var was_on_floor: bool = false
var fall_start_y: float = 0.0

var is_crouch_held: bool = false
var is_sliding: bool = false
var slide_timer: float = 0.0
var slide_direction: Vector3 = Vector3.ZERO

var bob_time: float = 0.0
var camera_base_y: float = 0.0
var landing_dip_offset: float = 0.0
var current_fov: float = 75.0
var current_tilt: float = 0.0
var target_tilt: float = 0.0

var current_speed_input: Vector2 = Vector2.ZERO  # smoothed input for lean/tilt


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	camera_base_y = head.position.y
	current_fov = fov_base
	camera.fov = fov_base


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		rotate_y(-event.relative.x * mouse_sensitivity)
		head.rotate_x(-event.relative.y * mouse_sensitivity)
		head.rotation.x = clamp(
			head.rotation.x,
			deg_to_rad(max_look_down_deg),
			deg_to_rad(max_look_up_deg)
		)

	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if event is InputEventMouseButton and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	_update_timers(delta)
	_handle_gravity(delta)
	_handle_jump_buffer()
	_handle_crouch_and_slide_input(delta)
	_handle_movement(delta)
	_apply_landing_detection()
	_update_camera_juice(delta)

	was_on_floor = is_on_floor()
	move_and_slide()


# ---------------------------------------------------------
# TIMERS: coyote time + jump buffer. These two alone remove
# most of the "why didn't my jump register" frustration.
# ---------------------------------------------------------
func _update_timers(delta: float) -> void:
	if is_on_floor():
		coyote_timer = coyote_time
	else:
		coyote_timer = max(0.0, coyote_timer - delta)

	if jump_buffer_timer > 0.0:
		jump_buffer_timer -= delta


func _handle_jump_buffer() -> void:
	if Input.is_action_just_pressed("jump"):
		jump_buffer_timer = jump_buffer_time

	var can_jump := coyote_timer > 0.0 and jump_buffer_timer > 0.0
	if can_jump:
		velocity.y = jump_velocity
		coyote_timer = 0.0
		jump_buffer_timer = 0.0
		if is_sliding:
			_end_slide()
		# small forward "hop" boost feels better than a dead-vertical jump
		var input_dir := _get_input_direction()
		if input_dir.length() > 0.1:
			velocity += (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized() * 1.2


# ---------------------------------------------------------
# GRAVITY: asymmetric rise/fall gravity is a classic feel trick.
# Falling faster than rising makes jumps feel punchy, not floaty.
# ---------------------------------------------------------
func _handle_gravity(delta: float) -> void:
	if not is_on_floor():
		var g_mult := fall_gravity_multiplier if velocity.y < 0 else gravity_multiplier
		velocity.y -= gravity * g_mult * delta
	else:
		if velocity.y < 0:
			velocity.y = -0.5  # keeps is_on_floor() stable on slopes/stairs


# ---------------------------------------------------------
# CROUCH + SLIDE
# ---------------------------------------------------------
func _handle_crouch_and_slide_input(delta: float) -> void:
	is_crouch_held = Input.is_action_pressed("crouch")

	var wants_slide := (
		Input.is_action_just_pressed("crouch")
		and is_on_floor()
		and not is_sliding
		and _get_horizontal_speed() >= min_slide_speed_to_start
		and (Input.is_action_pressed("sprint") or current_state == State.SPRINT)
	)

	if wants_slide:
		_start_slide()

	if is_sliding:
		slide_timer -= delta
		var slide_vel := slide_direction * slide_speed
		slide_vel = slide_vel.lerp(Vector3.ZERO, slide_friction * delta)
		velocity.x = slide_vel.x
		velocity.z = slide_vel.z
		# keep slide_speed reference updated so friction curve feels natural
		if slide_timer <= 0.0 or _get_horizontal_speed() < crouch_speed:
			_end_slide()

	# smooth capsule height change (crouch or slide both use crouched height)
	var want_crouched := is_crouch_held or is_sliding
	var target_height := crouch_height if want_crouched else standing_height
	var shape := collision_shape.shape as CapsuleShape3D
	if shape:
		shape.height = lerp(shape.height, target_height, crouch_transition_speed * delta)
		collision_shape.position.y = shape.height * 0.5
		head.position.y = lerp(head.position.y, shape.height - 0.15, crouch_transition_speed * delta)


func _start_slide() -> void:
	is_sliding = true
	slide_timer = slide_duration
	var dir := velocity
	dir.y = 0
	slide_direction = dir.normalized() if dir.length() > 0.1 else -transform.basis.z
	velocity.x = slide_direction.x * slide_speed
	velocity.z = slide_direction.z * slide_speed


func _end_slide() -> void:
	is_sliding = false


# ---------------------------------------------------------
# CORE MOVEMENT
# ---------------------------------------------------------
func _get_input_direction() -> Vector2:
	return Input.get_vector("move_left", "move_right", "move_forward", "move_back")


func _get_horizontal_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()


func _handle_movement(delta: float) -> void:
	if is_sliding:
		current_state = State.SLIDE
		return  # slide velocity already handled above

	var input_dir := _get_input_direction()
	current_speed_input = current_speed_input.lerp(input_dir, 10.0 * delta)
	var move_dir := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	var target_speed: float = walk_speed
	if is_crouch_held:
		current_state = State.CROUCH
		target_speed = crouch_speed
	elif Input.is_action_pressed("sprint") and input_dir.y < -0.1:  # sprint only moving forward
		current_state = State.SPRINT
		target_speed = sprint_speed
	else:
		current_state = State.WALK

	if not is_on_floor():
		current_state = State.AIR

	var accel: float
	if is_on_floor():
		accel = ground_accel if input_dir.length() > 0.1 else ground_decel
	else:
		accel = air_accel if input_dir.length() > 0.1 else air_decel

	var target_vel := move_dir * target_speed
	velocity.x = move_toward(velocity.x, target_vel.x, accel * target_speed * delta)
	velocity.z = move_toward(velocity.z, target_vel.z, accel * target_speed * delta)


# ---------------------------------------------------------
# LANDING DETECTION: feeds the camera dip effect
# ---------------------------------------------------------
func _apply_landing_detection() -> void:
	if not was_on_floor and is_on_floor():
		var fall_distance := fall_start_y - global_position.y
		if fall_distance > 1.0:
			landing_dip_offset = min(fall_distance * 0.03, landing_dip_strength)
	if not is_on_floor() and velocity.y <= 0.0 and was_on_floor:
		fall_start_y = global_position.y
	elif not is_on_floor():
		fall_start_y = max(fall_start_y, global_position.y)


# ---------------------------------------------------------
# CAMERA JUICE: head bob, landing dip, speed-based FOV, slide tilt.
# This is most of what makes movement "feel" good vs. just "work."
# ---------------------------------------------------------
func _update_camera_juice(delta: float) -> void:
	# --- Head bob (scales with speed, pauses when airborne/sliding) ---
	var h_speed := _get_horizontal_speed()
	if is_on_floor() and not is_sliding and h_speed > 0.3:
		bob_time += delta * bob_frequency * (h_speed / walk_speed)
		var bob_offset := sin(bob_time * TAU) * bob_amplitude * (h_speed / sprint_speed)
		head.position.y = lerp(head.position.y, camera_base_y + bob_offset, 15.0 * delta)
	else:
		bob_time = 0.0

	# --- Landing dip recovery ---
	landing_dip_offset = move_toward(landing_dip_offset, 0.0, landing_dip_recover_speed * delta)
	camera.position.y = lerp(camera.position.y, -landing_dip_offset, 20.0 * delta)

	# --- Slide camera tilt (roll into the slide) ---
	if is_sliding:
		target_tilt = deg_to_rad(tilt_amount_deg)
	else:
		target_tilt = 0.0
	current_tilt = lerp(current_tilt, target_tilt, 8.0 * delta)
	camera.rotation.z = current_tilt

	# --- Dynamic FOV: sprint and slide both punch FOV out slightly ---
	var target_fov := fov_base
	if is_sliding:
		target_fov = fov_base + fov_slide_add
	elif current_state == State.SPRINT:
		target_fov = fov_base + fov_sprint_add
	current_fov = lerp(current_fov, target_fov, fov_change_speed * delta)
	camera.fov = current_fov
