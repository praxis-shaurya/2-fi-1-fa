extends Control

# Attach this to a Control node that contains a ProgressBar child.
# Expected structure:
# StaminaBarUI (Control, this script)
#   ProgressBar

@export var player_path: CharacterBody3D

 # drag your CharacterBody3D player node here in the Inspector
@onready var bar: ProgressBar = $ProgressBar

func _process(delta: float) -> void:
	bar.value = lerp(bar.value, player_path.stamina, 8*delta)
