extends DialogicSubsystem

## Subsystem that handles showing of dialog text (+text effects & modifiers), name label, and next indicator

signal about_to_show_text(info:Dictionary)
signal text_finished(info:Dictionary)
signal speaker_updated(character:DialogicCharacter)
signal textbox_visibility_changed(visible:bool)
signal autoadvance_changed(enabled: bool)
signal animation_textbox_new_text
signal animation_textbox_show
signal animation_textbox_hide

# used to color names without searching for all characters each time
var character_colors := {}
var color_regex := RegEx.new()
var text_already_read := false

var text_effects := {}
var parsed_text_effect_info : Array[Dictionary]= []
var text_effects_regex := RegEx.new()
enum TextModifierModes {ALL=-1, TEXT_ONLY=0, CHOICES_ONLY=1}
enum TextTypes {DIALOG_TEXT, CHOICE_TEXT}
var text_modifiers := []
var input_handler :Node = null

var _autoadvance_enabled := false

# set by the [speed] effect, multies the letter speed and [pause] effects
var speed_multiplier := 1.0
# stores the pure letter speed (unmultiplied)
var _pure_letter_speed := 0.1
var _letter_speed_absolute := false

var _autopauses := {}

#region Auto-Skip
var auto_skip: AutoSkip = null

#endregion

####################################################################################################
##					STATE
####################################################################################################

func clear_game_state(clear_flag:=Dialogic.ClearFlags.FULL_CLEAR) -> void:
	update_dialog_text('', true)
	update_name_label(null)
	dialogic.current_state_info['speaker'] = null
	dialogic.current_state_info['text'] = ''

	set_skippable(ProjectSettings.get_setting('dialogic/text/skippable', true))

	set_autoadvance_system(ProjectSettings.get_setting('dialogic/text/autoadvance_enabled', false))
	var autoadvance_info := get_autoadvance_info()
	autoadvance_info['fixed_delay'] = ProjectSettings.get_setting('dialogic/text/autoadvance_fixed_delay', 1)
	autoadvance_info['per_word_delay'] = ProjectSettings.get_setting('dialogic/text/autoadvance_per_word_delay', 0)
	autoadvance_info['per_character_delay'] = ProjectSettings.get_setting('dialogic/text/autoadvance_per_character_delay', 0.1)
	autoadvance_info['ignored_characters_enabled'] = ProjectSettings.get_setting('dialogic/text/autoadvance_ignored_characters_enabled', true)
	autoadvance_info['ignored_characters'] = ProjectSettings.get_setting('dialogic/text/autoadvance_ignored_characters', {})

	for text_node in get_tree().get_nodes_in_group('dialogic_dialog_text'):
		if text_node.start_hidden:
			text_node.textbox_root.hide()

	set_manualadvance(true)


func load_game_state(load_flag:=LoadFlags.FULL_LOAD) -> void:
	update_dialog_text(dialogic.current_state_info.get('text', ''), true)
	var character:DialogicCharacter = null
	if dialogic.current_state_info.get('speaker', null):
		character = load(dialogic.current_state_info.get('speaker', null))

	if character:
		update_name_label(character)


func pause() -> void:
	input_handler.pause()


func resume() -> void:
	input_handler.resume()


####################################################################################################
##					MAIN METHODS
####################################################################################################

## Applies modifiers, effects and coloring to the text
func parse_text(text:String, type:int=TextTypes.DIALOG_TEXT, variables:= true, glossary:= true, modifiers:= true, effects:= true, color_names:= true) -> String:
	if variables and dialogic.has_subsystem('VAR'):
		text = dialogic.VAR.parse_variables(text)
	if glossary and dialogic.has_subsystem('Glossary'):
		text = dialogic.Glossary.parse_glossary(text)
	if modifiers:
		text = parse_text_modifiers(text, type)
	if effects:
		text = parse_text_effects(text)
	if color_names:
		text = color_names(text)
	return text


## Shows the given text on all visible DialogText nodes.
## Instant can be used to skip all revieling.
## If additional is true, the previous text will be kept.
func update_dialog_text(text:String, instant:bool= false, additional:= false) -> String:
	update_text_speed()

	if text.is_empty():
		await hide_text_boxes(instant)
	else:
		await show_text_boxes(instant)
		if !dialogic.current_state_info['text'].is_empty():
			animation_textbox_new_text.emit()
			if Dialogic.Animation.is_animating():
				await Dialogic.Animation.finished

	if !instant: dialogic.current_state = dialogic.States.SHOWING_TEXT
	dialogic.current_state_info['text'] = text
	for text_node in get_tree().get_nodes_in_group('dialogic_dialog_text'):
		if text_node.enabled and (text_node == text_node.textbox_root or text_node.textbox_root.is_visible_in_tree()):
			if instant:
				text_node.text = text
			else:
				text_node.reveal_text(text, additional)
				if !text_node.finished_revealing_text.is_connected(_on_dialog_text_finished):
					text_node.finished_revealing_text.connect(_on_dialog_text_finished)
			dialogic.current_state_info['text_parsed'] = (text_node as RichTextLabel).get_parsed_text()

	# also resets temporary autoadvance and noskip settings:
	speed_multiplier = 1

	set_autoadvance_until_next_event(false)
	set_autoadvance_override_delay_for_current_event(-1)
	set_skippable(true, true)
	set_manualadvance(true, true)

	return text


func _on_dialog_text_finished():
	text_finished.emit({'text':dialogic.current_state_info['text'], 'character':dialogic.current_state_info['speaker']})


func update_name_label(character:DialogicCharacter) -> void:
	var character_path = character.resource_path if character else null
	if character_path != dialogic.current_state_info.get('character'):
		dialogic.current_state_info['speaker'] = character_path
		speaker_updated.emit(character)
	for name_label in get_tree().get_nodes_in_group('dialogic_name_label'):
		if character:
			if dialogic.has_subsystem('VAR'):
				name_label.text = dialogic.VAR.parse_variables(character.display_name)
			else:
				name_label.text = character.display_name
			if !'use_character_color' in name_label or name_label.use_character_color:
				name_label.self_modulate = character.color
		else:
			name_label.text = ''
			name_label.self_modulate = Color(1,1,1,1)


func update_typing_sound_mood(mood:Dictionary = {}) -> void:
	for typing_sound in get_tree().get_nodes_in_group('dialogic_type_sounds'):
		typing_sound.load_overwrite(mood)


# instant skips the signal and thus possible animations
func hide_text_boxes(instant:=false) -> void:
	dialogic.current_state_info['text'] = ''
	var emitted := instant
	for name_label in get_tree().get_nodes_in_group('dialogic_name_label'):
		name_label.text = ""
	if !emitted and !get_tree().get_nodes_in_group('dialogic_dialog_text').is_empty() and get_tree().get_nodes_in_group('dialogic_dialog_text')[0].textbox_root.visible:
		animation_textbox_hide.emit()
		if Dialogic.Animation.is_animating():
			await Dialogic.Animation.finished
	for text_node in get_tree().get_nodes_in_group('dialogic_dialog_text'):
		if text_node.textbox_root.visible and !emitted:
			textbox_visibility_changed.emit(false)
			emitted = true
		text_node.textbox_root.hide()


func is_textbox_visible() -> bool:
	return get_tree().get_nodes_in_group('dialogic_dialog_text').any(func(x): return x.textbox_root.visible)


# instant skips the signal and thus possible animations
func show_text_boxes(instant:=false) -> void:
	var emitted := instant
	for text_node in get_tree().get_nodes_in_group('dialogic_dialog_text'):
		if !text_node.textbox_root.visible and !emitted:
			animation_textbox_show.emit()
			text_node.textbox_root.show()
			if Dialogic.Animation.is_animating():
				await Dialogic.Animation.finished
			textbox_visibility_changed.emit(true)
			emitted = true
		else:
			text_node.textbox_root.show()


func show_next_indicators(question=false, autoadvance=false) -> void:
	for next_indicator in get_tree().get_nodes_in_group('dialogic_next_indicator'):
		if (question and 'show_on_questions' in next_indicator and next_indicator.show_on_questions) or \
			(autoadvance and 'show_on_autoadvance' in next_indicator and next_indicator.show_on_autoadvance) or (!question and !autoadvance):
			next_indicator.show()

func hide_next_indicators(_fake_arg = null) -> void:
	for next_indicator in get_tree().get_nodes_in_group('dialogic_next_indicator'):
		next_indicator.hide()


func update_text_speed(letter_speed:float = -1, absolute:bool = false, _speed_multiplier:float= -1, _user_speed:float=-1) -> void:
	if letter_speed == -1:
		letter_speed = ProjectSettings.get_setting('dialogic/text/letter_speed', 0.01)
	_pure_letter_speed = letter_speed
	_letter_speed_absolute = absolute

	if _speed_multiplier == -1:
		_speed_multiplier = speed_multiplier
	else:
		speed_multiplier = _speed_multiplier

	if _user_speed == -1:
		_user_speed = Dialogic.Settings.get_setting('text_speed', 1)


	for text_node in get_tree().get_nodes_in_group('dialogic_dialog_text'):
		if absolute:
			text_node.lspeed = letter_speed
		else:
			text_node.lspeed = letter_speed*_speed_multiplier*_user_speed



##################### AUTOADVANCE SYSTEM ###########################################################
####################################################################################################

## Returns whether autoadvance is currently considered enabled.
## Autoadvance is considered on if any of these flags is true:
## - waiting_for_user_input (becomes false on any dialogic input action)
## - waiting_for_next_event (becomes false on each text event)
## - waiting_for_system (becomes false only when disabled via code)
##
## All three can be set with dedicated methods.
func is_autoadvance_enabled() -> bool:
	return (get_autoadvance_info()['waiting_for_next_event']
		or get_autoadvance_info()['waiting_for_user_input']
		or get_autoadvance_info()['waiting_for_system'])


## Fetches all Auto-Advance settings.
## If they don't exist, returns the default settings.
## The key's values will be changed upon setting them.
func get_autoadvance_info() -> Dictionary:
	if not dialogic.current_state_info.has('autoadvance'):
		dialogic.current_state_info['autoadvance'] = {
		'waiting_for_next_event' : false,
		'waiting_for_user_input' : false,
		'waiting_for_system' : false,
		'fixed_delay' : 1,
		'per_word_delay' : 0,
		'per_character_delay' : 0.1,
		'ignored_characters_enabled' : false,
		'ignored_characters' : {},
		'override_delay_for_current_event' : -1,
		'await_playing_voice' : true,
		}
	return dialogic.current_state_info['autoadvance']


## Updates the [member _autoadvance_enabled] variable to properly check if the value has changed.
## If it changed, emits the [member autoadvance_changed] signal.
func _emit_autoadvance_enabled() -> void:
	var old_autoadvance_state = _autoadvance_enabled
	_autoadvance_enabled = is_autoadvance_enabled()

	if old_autoadvance_state != _autoadvance_enabled:
		autoadvance_changed.emit(_autoadvance_enabled)


## Sets the autoadvance waiting_for_user_input flag to [param enabled].
func set_autoadvance_until_unread_message(enabled: bool) -> void:
	var info := get_autoadvance_info()
	info['waiting_for_user_input'] = enabled

	_emit_autoadvance_enabled()


## Sets the autoadvance waiting_for_system flag to [param enabled].
func set_autoadvance_system(enabled: bool) -> void:
	var info := get_autoadvance_info()
	info['waiting_for_system'] = enabled

	_emit_autoadvance_enabled()


## Sets the autoadvance waiting_for_next_event flag to [param enabled].
func set_autoadvance_until_next_event(enabled: bool) -> void:
	var info := get_autoadvance_info()
	info['waiting_for_next_event'] = enabled

	_emit_autoadvance_enabled()


func _update_autoadvance_delay_modifier(delay_modifier: float) -> void:
	var info: Dictionary = get_autoadvance_info()
	info['delay_modifier'] = delay_modifier


func set_autoadvance_override_delay_for_current_event(delay_time := -1.0) -> void:
	var info := get_autoadvance_info()
	info['override_delay_for_current_event'] = delay_time


func get_autoadvance_time() -> float:
	return input_handler.get_autoadvance_time()


## Returns the progress of the auto-advance timer on a scale between 0 and 1.
## The higher the value, the closer the timer is to finishing.
## If auto-advancing is disabled, returns -1.
func get_autoadvance_progress() -> float:
	if !input_handler.is_autoadvancing():
		return -1

	var total_time: float = get_autoadvance_time()
	var time_left: float = input_handler.get_autoadvance_time_left()
	var progress: float = (total_time - time_left) / total_time

	return progress

##################### MANUAL ADVANCE ###############################################################
####################################################################################################

func set_manualadvance(enabled:=true, temp:= false) -> void:
	if !dialogic.current_state_info.has('manual_advance'):
		dialogic.current_state_info['manual_advance'] = {'enabled':false, 'temp_enabled':false}
	if temp:
		dialogic.current_state_info['manual_advance']['temp_enabled'] = enabled
	else:
		dialogic.current_state_info['manual_advance']['enabled'] = enabled


func can_manual_advance() -> bool:
	return dialogic.current_state_info['manual_advance']['enabled'] and dialogic.current_state_info['manual_advance'].get('temp_enabled', true)


func set_skippable(skippable:= true, temp:=false) -> void:
	if !dialogic.current_state_info.has('skippable'):
		dialogic.current_state_info['skippable'] = {'enabled':false, 'temp_enabled':false}
	if temp:
		dialogic.current_state_info['skippable']['temp_enabled'] = skippable
	else:
		dialogic.current_state_info['skippable']['enabled'] = skippable


func can_skip() -> bool:
	return dialogic.current_state_info['skippable']['enabled'] and dialogic.current_state_info['skippable'].get('temp_enabled', true)


################### Text Effects & Modifiers ###################################################
####################################################################################################

func collect_text_effects() -> void:
	var text_effect_names := ""
	text_effects.clear()
	for indexer in DialogicUtil.get_indexers(true):
		for effect in indexer._get_text_effects():
			text_effects[effect.command] = {}
			if effect.has('subsystem') and effect.has('method'):
				text_effects[effect.command]['callable'] = Callable(Dialogic.get_subsystem(effect.subsystem), effect.method)
			elif effect.has('node_path') and effect.has('method'):
				text_effects[effect.command]['callable'] = Callable(get_node(effect.node_path), effect.method)
			else:
				continue
			text_effect_names += effect.command +"|"
	text_effects_regex.compile("(?<!\\\\)\\[\\s*(?<command>"+text_effect_names.trim_suffix("|")+")\\s*(=\\s*(?<value>.+?)\\s*)?\\]")


## Returns the string with all text effects removed
## Use get_parsed_text_effects() after calling this to get all effect information
func parse_text_effects(text:String) -> String:
	parsed_text_effect_info.clear()
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	var position_correction := 0
	var bbcode_correction := 0
	for effect_match in text_effects_regex.search_all(text):
		rtl.text = text.substr(0, effect_match.get_start()-position_correction)
		bbcode_correction = effect_match.get_start()-position_correction-len(rtl.get_parsed_text())
		# append [index] = [command, value] to effects dict
		parsed_text_effect_info.append({'index':effect_match.get_start()-position_correction-bbcode_correction, 'execution_info':text_effects[effect_match.get_string('command')], 'value': effect_match.get_string('value').strip_edges()})

		text = text.substr(0,effect_match.get_start()-position_correction)+text.substr(effect_match.get_start()-position_correction+len(effect_match.get_string()))

		position_correction += len(effect_match.get_string())
	text = text.replace('\\[', '[')
	rtl.queue_free()
	return text


func execute_effects(current_index:int, text_node:Control, skipping:bool= false) -> void:
	# might have to execute multiple effects
	while true:
		if parsed_text_effect_info.is_empty():
			return
		if current_index != -1 and current_index < parsed_text_effect_info[0]['index']:
			return
		var effect :Dictionary=  parsed_text_effect_info.pop_front()
		await (effect['execution_info']['callable'] as Callable).call(text_node, skipping, effect['value'])


func collect_text_modifiers() -> void:
	text_modifiers.clear()
	for indexer in DialogicUtil.get_indexers(true):
		for modifier in indexer._get_text_modifiers():
			if modifier.has('subsystem') and modifier.has('method'):
				text_modifiers.append({'method':Callable(Dialogic.get_subsystem(modifier.subsystem), modifier.method)})
			elif modifier.has('node_path') and modifier.has('method'):
				text_modifiers.append({'method':Callable(get_node(modifier.node_path), modifier.method)})
			text_modifiers[-1]['mode'] = modifier.get('mode', TextModifierModes.TEXT_ONLY)


func parse_text_modifiers(text:String, type:int=TextTypes.DIALOG_TEXT) -> String:
	for mod in text_modifiers:
		if mod.mode != TextModifierModes.ALL and type != -1 and  type != mod.mode:
			continue
		text = mod.method.call(text)
	return text


func skip_text_animation() -> void:
	for text_node in get_tree().get_nodes_in_group('dialogic_dialog_text'):
		if text_node.is_visible_in_tree():
			text_node.finish_text()
	if dialogic.has_subsystem('Voice'):
		dialogic.Voice.stop_audio()


func get_current_speaker() -> DialogicCharacter:
	return (load(dialogic.current_state_info['speaker']) as DialogicCharacter)


#################### HELPERS & OTHER STUFF #########################################################
####################################################################################################

func _ready():
	collect_character_names()
	collect_text_effects()
	collect_text_modifiers()
	Dialogic.event_handled.connect(hide_next_indicators)

	auto_skip = AutoSkip.new()

	_autopauses = {}
	var autopause_data :Dictionary= ProjectSettings.get_setting('dialogic/text/autopauses', {})
	for i in autopause_data.keys():
		_autopauses[RegEx.create_from_string('(?<!(\\[|\\{))['+i+'](?!([\\w\\s]*!?[\\]\\}]|$))')] = autopause_data[i]
	input_handler = Node.new()
	input_handler.set_script(load(get_script().resource_path.get_base_dir().path_join('default_input_handler.gd')))
	add_child(input_handler)


func post_install():
	Dialogic.Settings.connect_to_change('text_speed', _update_user_speed)
	Dialogic.Settings.connect_to_change('autoadvance_delay_modifier', _update_autoadvance_delay_modifier)


func _update_user_speed(user_speed:float) -> void:
	update_text_speed(_pure_letter_speed, _letter_speed_absolute)


func color_names(text:String) -> String:
	if !ProjectSettings.get_setting('dialogic/text/autocolor_names', false):
		return text

	var counter := 0
	for result in color_regex.search_all(text):
		text = text.insert(result.get_start("name")+((9+8+8)*counter), '[color=#' + character_colors[result.get_string('name')].to_html() + ']')
		text = text.insert(result.get_end("name")+9+8+((9+8+8)*counter), '[/color]')
		counter += 1

	return text


func collect_character_names() -> void:
	#don't do this at all if we're not using autocolor names to begin with
	if !ProjectSettings.get_setting('dialogic/text/autocolor_names', false):
		return

	character_colors = {}
	for dch_path in DialogicUtil.list_resources_of_type('.dch'):
		var dch := (load(dch_path) as DialogicCharacter)

		if dch.display_name:
			character_colors[dch.display_name] = dch.color

		for nickname in dch.nicknames:
			if nickname.strip_edges():
				character_colors[nickname.strip_edges()] = dch.color

	color_regex.compile('(?<=\\W|^)(?<name>'+str(character_colors.keys()).trim_prefix('["').trim_suffix('"]').replace('", "', '|')+')(?=\\W|$)')


################################################################################
## 				DEFAULT TEXT EFFECTS & MODIFIERS
################################################################################

func effect_pause(text_node:Control, skipped:bool, argument:String) -> void:
	if skipped:
		return

	# We want to ignore pauses if we're skipping.
	if not auto_skip.enabled:
		return

	var text_speed = Dialogic.Settings.get_setting('text_speed', 1)

	if argument:

		if argument.ends_with('!'):
			await get_tree().create_timer(float(argument.trim_suffix('!'))).timeout
		elif speed_multiplier != 0 and Dialogic.Settings.get_setting('text_speed', 1) != 0:
			await get_tree().create_timer(float(argument)*speed_multiplier*Dialogic.Settings.get_setting('text_speed', 1)).timeout
	elif speed_multiplier != 0 and Dialogic.Settings.get_setting('text_speed', 1) != 0:
		await get_tree().create_timer(0.5*speed_multiplier*Dialogic.Settings.get_setting('text_speed', 1)).timeout


func effect_speed(text_node:Control, skipped:bool, argument:String) -> void:
	if skipped:
		return
	if argument:
		update_text_speed(-1, false, float(argument), -1)
	else:
		update_text_speed(-1, false, 1, -1)


func effect_lspeed(text_node:Control, skipped:bool, argument:String) -> void:
	if skipped:
		return
	if argument:
		if argument.ends_with('!'):
			update_text_speed(float(argument.trim_suffix('!')), true)
		else:
			update_text_speed(float(argument), false)
	else:
		update_text_speed()


func effect_signal(text_node:Control, skipped:bool, argument:String) -> void:
	Dialogic.text_signal.emit(argument)


func effect_mood(text_node:Control, skipped:bool, argument:String) -> void:
	if argument.is_empty(): return
	if Dialogic.current_state_info.get('character', null):
		update_typing_sound_mood(
			load(Dialogic.current_state_info.character).custom_info.get('sound_moods', {}).get(argument, {}))


func effect_input(text_node:Control, skipped:bool, argument:String) -> void:
	if skipped:
		return
	show_next_indicators()
	await input_handler.dialogic_action_priority
	hide_next_indicators()
	input_handler.action_was_consumed = true


func effect_noskip(text_node:Control, skipped:bool, argument:String) -> void:
	set_skippable(false, true)
	set_manualadvance(false, true)
	effect_autoadvance(text_node, skipped, argument)


func effect_autoadvance(text_node: Control, skipped:bool, argument:String) -> void:
	if argument.ends_with('?'):
		argument = argument.trim_suffix('?')
	else:
		set_autoadvance_until_next_event(true)

	if argument.is_valid_float():
		set_autoadvance_override_delay_for_current_event(float(argument))


var modifier_words_select_regex := RegEx.create_from_string("(?<!\\\\)\\<[^\\[\\>]+(\\/[^\\>]*)\\>")
func modifier_random_selection(text:String) -> String:
	for replace_mod_match in modifier_words_select_regex.search_all(text):
		var string :String= replace_mod_match.get_string().trim_prefix("<").trim_suffix(">")
		string = string.replace('//', '<slash>')
		var list :PackedStringArray= string.split('/')
		var item :String= list[randi()%len(list)]
		item = item.replace('<slash>', '/')
		text = text.replace(replace_mod_match.get_string(), item.strip_edges())
	return text


func modifier_break(text:String) -> String:
	return text.replace('[br]', '\n')


func modifier_autopauses(text:String) -> String:
	var absolute := ProjectSettings.get_setting('dialogic/text/absolute_autopauses', false)
	for i in _autopauses.keys():
		var offset := 0
		for result in i.search_all(text):
			if absolute:
				text = text.insert(result.get_end()+offset, '[pause='+str(_autopauses[i])+'!]')
				offset += len('[pause='+str(_autopauses[i])+'!]')
			else:
				text = text.insert(result.get_end()+offset, '[pause='+str(_autopauses[i])+']')
				offset += len('[pause='+str(_autopauses[i])+']')
	return text
