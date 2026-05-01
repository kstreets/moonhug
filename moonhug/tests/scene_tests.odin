package tests

import "../engine"
import "../app"

import "core:testing"
import "core:os"
import "core:strings"
import "core:encoding/json"
import "core:encoding/uuid"

@(private)
TestCtx :: struct {
	world: engine.World,
	uc:    engine.UserContext,
	scene: ^engine.Scene,
	path:  string,
}

@(private)
_serializers_registered: bool

@(private)
_tween_initialized: bool

@(private)
setup :: proc(tc: ^TestCtx, path: string = "") {
	app.register_type_guids()
	if !_serializers_registered {
		app.register_component_serializers()
		// Mirror editor/main.odin: nested_scene_revert_override needs pointer
		// typeids for primitive field types (position, color, scale, …) so it
		// can hand a properly-typed `any` to json.unmarshal_any.
		engine.register_pointer_type(bool)
		engine.register_pointer_type(int)
		engine.register_pointer_type(i32)
		engine.register_pointer_type(u32)
		engine.register_pointer_type(f32)
		engine.register_pointer_type(f64)
		engine.register_pointer_type(string)
		_serializers_registered = true
	}
	if !_tween_initialized {
		engine.tween_init()
		_tween_initialized = true
	}
	engine.w_init(&tc.world)
	tc.uc.world = &tc.world
	tc.path = path
	context.user_ptr = &tc.uc
	tc.scene = engine.scene_new()
	engine.sm_scene_set_active(tc.scene)
	engine.scene_ensure_root(tc.scene)
}

@(private)
teardown :: proc(tc: ^TestCtx) {
	if tc.scene != nil {
		engine.sm_scene_destroy_or_unload(tc.scene)
	}
	engine.sm_scene_set_active(nil)
	engine.world_destroy_all(&tc.world)
	if tc.path != "" do os.remove(tc.path)
}

// Helpers for next_local_id invariant ---------------------------------------

@(private)
_max_local_id_in_file :: proc(sf: ^engine.SceneFile) -> engine.Local_ID {
	max_id := engine.Local_ID(0)
	bump :: proc(m: ^engine.Local_ID, v: engine.Local_ID) {
		if v > m^ do m^ = v
	}
	for &tr in sf.transforms {
		bump(&max_id, tr.local_id)
		for &c in tr.components do bump(&max_id, c.local_id)
	}
	for &c in sf.cameras          do bump(&max_id, c.local_id)
	for &c in sf.lifetimes        do bump(&max_id, c.local_id)
	for &c in sf.players          do bump(&max_id, c.local_id)
	for &c in sf.scripts          do bump(&max_id, c.local_id)
	for &c in sf.sprite_renderers do bump(&max_id, c.local_id)
	for &ns in sf.nested_scenes   do bump(&max_id, ns.local_id)
	for &bc in sf.breadcrumbs     do bump(&max_id, bc.local_id)
	return max_id
}

// Saving a scene must persist next_local_id strictly greater than any local_id
// the file actually contains. Otherwise a future scene_next_id() call will hand
// out an id that collides with an existing transform/component, and on reload
// the duplicated id can make a regular transform look like the host of a
// NestedScene record (see _nested_scene_find_outer_non_nested in nested_scene.odin).
@(test)
test_save_writes_next_local_id_above_max_used :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_next_id_invariant.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	rootH := engine.Transform_Handle(tc_mem.scene.root.handle)
	childH := engine.transform_new("Child", rootH)
	_, sr := engine.transform_get_or_add_comp(childH, engine.SpriteRenderer)
	testing.expect(t, sr != nil)

	// Simulate the c.scene-style corrupt state: a transform's local_id is far
	// above scene.next_local_id. This mirrors how the bug manifested on disk
	// (next_local_id=4 while transforms used 15/16).
	child_t := engine.pool_get(&tc_mem.world.transforms, engine.Handle(childH))
	testing.expect(t, child_t != nil)
	if child_t == nil do return
	child_t.local_id = 999

	ok := engine.scene_save(tc_mem.scene, tc_mem.path)
	testing.expect(t, ok, "scene_save should succeed")
	if !ok do return

	sf, fok := engine.scene_file_load(tc_mem.path)
	testing.expect(t, fok)
	if !fok do return
	defer engine.scene_file_destroy(&sf)

	max_used := _max_local_id_in_file(&sf)
	testing.expect(t, sf.next_local_id > max_used,
		"saved next_local_id must be greater than every persisted local_id")
}

// Sanity: a regular transform with no NestedScene records pointing at it must
// not be reported as a nested-scene host after save+reload. This is the user-
// visible symptom of the c.scene bug where Environment was mislabelled as a
// nested scene.
@(test)
test_save_reload_regular_transforms_not_marked_nested :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_no_nested_marking.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	rootH := engine.Transform_Handle(tc_mem.scene.root.handle)
	envH := engine.transform_new("Environment", rootH)
	otherH := engine.transform_new("Player", rootH)
	testing.expect(t, envH != {} && otherH != {})

	ok := engine.scene_save(tc_mem.scene, tc_mem.path)
	testing.expect(t, ok)
	if !ok do return

	loaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	// No NestedScene records were ever added, so neither transform should
	// resolve as a nested host nor display the [nested scene] suffix.
	env_loaded := find_transform_named(&tc_mem.world, loaded, "Environment", false)
	other_loaded := find_transform_named(&tc_mem.world, loaded, "Player", false)
	testing.expect(t, env_loaded != {} && other_loaded != {})

	testing.expect(t, engine.scene_find_nested_scene_for_host(loaded, env_loaded) == nil,
		"Environment must not be reported as a nested-scene host")
	testing.expect(t, engine.scene_find_nested_scene_for_host(loaded, other_loaded) == nil,
		"Player must not be reported as a nested-scene host")
	testing.expect(t, !hierarchy_shows_nested_scene_suffix(&tc_mem.world, env_loaded),
		"hierarchy must not show nested-scene suffix on Environment")
	testing.expect(t, !hierarchy_shows_nested_scene_suffix(&tc_mem.world, other_loaded),
		"hierarchy must not show nested-scene suffix on Player")
}

@(test)
test_save_load_empty_scene :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_empty.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	ok := engine.scene_save(tc_mem.scene, tc_mem.path)
	testing.expect(t, ok, "scene_save should succeed")

	want_root_lid := engine.Local_ID(0)
	if rt := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc_mem.scene.root.handle)); rt != nil {
		want_root_lid = rt.local_id
	}
	want_next := tc_mem.scene.next_local_id

	loaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, loaded != nil, "scene_load should return non-nil")
	if loaded == nil do return

	testing.expect_value(t, loaded.next_local_id, want_next)
	testing.expect_value(t, loaded.root.pptr.local_id, want_root_lid)

	tc_mem.scene = loaded
}

@(test)
test_save_load_scene_with_transform :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_transform.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	tH := engine.transform_new("Player")
	engine.scene_set_root(tc_mem.scene, tH)

	transform := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tH))
	transform.position = {1, 2, 3}
	transform.scale = {4, 5, 6}

	ok := engine.scene_save(tc_mem.scene, tc_mem.path)
	testing.expect(t, ok, "scene_save should succeed")

	loaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, loaded != nil, "scene_load should return non-nil")
	if loaded == nil do return
	tc_mem.scene = loaded

	testing.expect(t, loaded.root.pptr.local_id != 0, "root should be set")

	loaded_t := engine.pool_get(&tc_mem.world.transforms, loaded.root.handle)
	testing.expect(t, loaded_t != nil, "loaded Transform should exist in pool")
	if loaded_t == nil do return
	testing.expect_value(t, loaded_t.name, "Player")
	testing.expect_value(t, loaded_t.position, [3]f32{1, 2, 3})
	testing.expect_value(t, loaded_t.scale, [3]f32{4, 5, 6})
}

@(test)
test_save_load_scene_with_sprite_renderer :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_sprite_renderer.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	tH := engine.transform_new("Player")
	engine.scene_set_root(tc_mem.scene, tH)

	_, sr := engine.transform_get_or_add_comp(tH, engine.SpriteRenderer)
	testing.expect(t, sr != nil, "SpriteRenderer should be added")
	if sr == nil do return
	sr.color = {1, 0, 0.5, 1}
	sr.enabled = true

	ok := engine.scene_save(tc_mem.scene, tc_mem.path)
	testing.expect(t, ok, "scene_save should succeed")

	loaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, loaded != nil, "scene_load should return non-nil")
	if loaded == nil do return
	tc_mem.scene = loaded

	testing.expect(t, loaded.root.pptr.local_id != 0, "root should be set")

	loaded_t := engine.pool_get(&tc_mem.world.transforms, loaded.root.handle)
	testing.expect(t, loaded_t != nil, "loaded Transform should exist in pool")
	if loaded_t == nil do return
	testing.expect_value(t, loaded_t.name, "Player")
	testing.expect_value(t, len(loaded_t.components), 1)

	_, loaded_sr := engine.transform_get_comp(engine.Transform_Handle(loaded.root.handle), engine.SpriteRenderer)
	testing.expect(t, loaded_sr != nil, "loaded SpriteRenderer should exist")
	if loaded_sr == nil do return
	testing.expect_value(t, loaded_sr.color, [4]f32{1, 0, 0.5, 1})
	testing.expect_value(t, loaded_sr.enabled, true)
	testing.expect(t, loaded_sr.owner == engine.Transform_Handle(loaded.root.handle), "SpriteRenderer owner should point to loaded transform")
}

@(test)
test_instantiate_twice_no_local_id_collision :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	parentH := engine.transform_new("Parent")
	childH := engine.transform_new("Child", parentH)
	_, sr := engine.transform_get_or_add_comp(childH, engine.SpriteRenderer)
	if sr == nil do return
	sr.color = {1, 0, 0, 1}
	sr.enabled = true

	data := engine.scene_copy_subtree(parentH)
	defer delete(data)
	testing.expect(t, len(data) > 0, "scene_copy_subtree should produce data")
	if len(data) == 0 do return

	rootH := engine.Transform_Handle(tc_mem.scene.root.handle)

	inst1 := engine.scene_paste_subtree(data, rootH)
	testing.expect(t, inst1 != {}, "first instantiate should succeed")

	inst2 := engine.scene_paste_subtree(data, rootH)
	testing.expect(t, inst2 != {}, "second instantiate should succeed")

	if inst1 == {} || inst2 == {} do return

	ids: map[engine.Local_ID]bool
	defer delete(ids)
	collision := false

	_collect_local_ids :: proc(w: ^engine.World, tH: engine.Transform_Handle, ids: ^map[engine.Local_ID]bool, collision: ^bool) {
		tr := engine.pool_get(&w.transforms, engine.Handle(tH))
		if tr == nil do return
		if tr.local_id in ids^ {
			collision^ = true
		}
		ids^[tr.local_id] = true
		for &c in tr.components {
			if c.local_id in ids^ {
				collision^ = true
			}
			ids^[c.local_id] = true
		}
		for child in tr.children {
			_collect_local_ids(w, engine.Transform_Handle(child.handle), ids, collision)
		}
	}

	_collect_local_ids(&tc_mem.world, inst1, &ids, &collision)
	_collect_local_ids(&tc_mem.world, inst2, &ids, &collision)

	testing.expect(t, !collision, "instantiating same subtree twice should not produce local_id collisions")
}

@(test)
test_instantiate_preserves_internal_cross_refs :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	parentH := engine.transform_new("Parent")
	c1H := engine.transform_new("Child1", parentH)
	c2H := engine.transform_new("Child2", parentH)
	_, sr := engine.transform_get_or_add_comp(c1H, engine.SpriteRenderer)
	if sr == nil do return
	sr.enabled = true

	data := engine.scene_copy_subtree(parentH)
	defer delete(data)
	testing.expect(t, len(data) > 0, "copy should succeed")
	if len(data) == 0 do return

	rootH := engine.Transform_Handle(tc_mem.scene.root.handle)
	inst := engine.scene_paste_subtree(data, rootH)
	testing.expect(t, inst != {}, "paste should succeed")
	if inst == {} do return

	inst_t := engine.pool_get(&tc_mem.world.transforms, engine.Handle(inst))
	testing.expect(t, inst_t != nil, "instantiated root should exist")
	if inst_t == nil do return
	testing.expect_value(t, inst_t.name, "Parent")
	testing.expect_value(t, len(inst_t.children), 2)

	if len(inst_t.children) < 2 do return

	child1_h := inst_t.children[0].handle
	child2_h := inst_t.children[1].handle
	child1 := engine.pool_get(&tc_mem.world.transforms, child1_h)
	child2 := engine.pool_get(&tc_mem.world.transforms, child2_h)
	testing.expect(t, child1 != nil, "child1 should exist")
	testing.expect(t, child2 != nil, "child2 should exist")
	if child1 == nil || child2 == nil do return

	testing.expect_value(t, child1.name, "Child1")
	testing.expect_value(t, child2.name, "Child2")
	testing.expect_value(t, child1.parent.handle, engine.Handle(inst))
	testing.expect_value(t, child2.parent.handle, engine.Handle(inst))

	_, inst_sr := engine.transform_get_comp(engine.Transform_Handle(child1_h), engine.SpriteRenderer)
	testing.expect(t, inst_sr != nil, "instantiated SpriteRenderer should exist")
	if inst_sr == nil do return
	testing.expect_value(t, inst_sr.enabled, true)
	testing.expect(t, inst_sr.owner == engine.Transform_Handle(child1_h), "SpriteRenderer owner should point to instantiated child")
}

@(test)
test_scene_file_remap_produces_unique_ids :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	parentH := engine.transform_new("A")
	childH := engine.transform_new("B", parentH)
	_, sr := engine.transform_get_or_add_comp(childH, engine.SpriteRenderer)
	if sr == nil do return

	data := engine.scene_copy_subtree(parentH)
	defer delete(data)
	if len(data) == 0 do return

	sf: engine.SceneFile
	if err := json.unmarshal(data, &sf); err != nil do return
	defer engine.scene_file_destroy(&sf)

	original_root := sf.root
	original_ids: [dynamic]engine.Local_ID
	defer delete(original_ids)
	for &tr in sf.transforms {
		append(&original_ids, tr.local_id)
	}

	engine._scene_file_remap_local_ids(&sf, tc_mem.scene)

	testing.expect(t, sf.root != original_root, "root local_id should be remapped")

	for tr, i in sf.transforms {
		testing.expect(t, tr.local_id != original_ids[i], "transform local_id should change after remap")
	}

	seen: map[engine.Local_ID]bool
	defer delete(seen)
	unique := true
	for tr in sf.transforms {
		if tr.local_id in seen { unique = false }
		seen[tr.local_id] = true
	}
	for c in sf.sprite_renderers {
		if c.local_id in seen { unique = false }
		seen[c.local_id] = true
	}
	testing.expect(t, unique, "all remapped ids should be unique")
}

@(test)
test_instantiate_remaps_tween_subject_ref :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	parentH := engine.transform_new("Parent")
	target1H := engine.transform_new("Target1", parentH)
	target2H := engine.transform_new("Target2", parentH)

	t1 := engine.pool_get(&tc_mem.world.transforms, engine.Handle(target1H))
	t2 := engine.pool_get(&tc_mem.world.transforms, engine.Handle(target2H))
	if t1 == nil || t2 == nil do return
	t1_lid := t1.local_id
	t2_lid := t2.local_id

	_, player := engine.transform_get_or_add_comp(parentH, engine.Player)
	if player == nil do return

	move := engine.TweenMoveToLocal{ position = {10, 20, 30}, duration = 1.0 }
	move.subject = engine.Ref{ pptr = engine.PPtr{local_id = t1_lid}, handle = engine.Handle(target1H) }

	scale := engine.TweenScaleToLocal{ scale = {2, 2, 2}, duration = 0.5 }
	scale.subject = engine.Ref{ pptr = engine.PPtr{local_id = t2_lid}, handle = engine.Handle(target2H) }

	seq := engine.Sequence{}
	append(&seq.children, engine.TweenUnion(move))
	append(&seq.children, engine.TweenUnion(scale))
	append(&player.animations, engine.TweenUnion(seq))
	seq.children = {}

	data := engine.scene_copy_subtree(parentH)
	defer delete(data)
	if len(data) == 0 do return

	rootH := engine.Transform_Handle(tc_mem.scene.root.handle)
	inst := engine.scene_paste_subtree(data, rootH)
	testing.expect(t, inst != {}, "paste should succeed")
	if inst == {} do return

	inst_t := engine.pool_get(&tc_mem.world.transforms, engine.Handle(inst))
	if inst_t == nil do return
	testing.expect_value(t, len(inst_t.children), 2)
	if len(inst_t.children) < 2 do return

	inst_t1 := engine.pool_get(&tc_mem.world.transforms, inst_t.children[0].handle)
	inst_t2 := engine.pool_get(&tc_mem.world.transforms, inst_t.children[1].handle)
	if inst_t1 == nil || inst_t2 == nil do return
	inst_t1_lid := inst_t1.local_id
	inst_t2_lid := inst_t2.local_id

	_, inst_player := engine.transform_get_comp(inst, engine.Player)
	if inst_player == nil do return
	testing.expect_value(t, len(inst_player.animations), 1)
	if len(inst_player.animations) < 1 do return

	inst_seq := &inst_player.animations[0].(engine.Sequence)
	testing.expect_value(t, len(inst_seq.children), 2)
	if len(inst_seq.children) < 2 do return

	child0 := engine.tween_base(&inst_seq.children[0])
	child1 := engine.tween_base(&inst_seq.children[1])

	testing.expect(t, child0.subject.pptr.local_id != t1_lid,
		"child0 subject should differ from original")
	testing.expect(t, child0.subject.pptr.local_id == inst_t1_lid,
		"child0 subject should be remapped to instantiated Target1")

	testing.expect(t, child1.subject.pptr.local_id != t2_lid,
		"child1 subject should differ from original")
	testing.expect(t, child1.subject.pptr.local_id == inst_t2_lid,
		"child1 subject should be remapped to instantiated Target2")
}

// nested_scene_revert_override is the user-facing "revert" UX: drop a specific
// override and restore the field to the baked base value. End-to-end coverage:
// modify a nested-owned transform, save (captures the override), reload (so the
// override lives in NestedScene.overrides), call revert, then assert the
// override is gone AND the live field has snapped back to the prefab's base.
@(test)
test_revert_override_restores_base_value :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_revert_override.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	// Use TestB directly (not TestA) so there is exactly one TransformC in the
	// world. nested_scene_revert_override walks the transform pool by local_id,
	// and TestA produces two TransformC instances which makes the test
	// ambiguous in a way unrelated to the revert path itself.
	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/TestB.scene")
	testing.expect(t, loaded != nil)
	if loaded == nil do return
	tc_mem.scene = loaded

	host_c := find_transform_named(&tc_mem.world, loaded, "TestC", false)
	transform_c_h := find_nested_named_under_host(&tc_mem.world, loaded, host_c, "TransformC")
	testing.expect(t, host_c != {} && transform_c_h != {})
	if host_c == {} || transform_c_h == {} do return

	// Mutate the nested transform's position so a "position" override is
	// produced on save.
	t_c := engine.pool_get(&tc_mem.world.transforms, engine.Handle(transform_c_h))
	testing.expect(t, t_c != nil)
	if t_c == nil do return
	t_c.position = {99, 99, 99}

	testing.expect(t, engine.scene_save(loaded, tc_mem.path))

	// Sanity-check: the on-disk file must carry the new override.
	{
		sf, fok := engine.scene_file_load(tc_mem.path)
		testing.expect(t, fok)
		on_disk_has_pos := false
		if fok {
			for ns2 in sf.nested_scenes {
				for ov in ns2.overrides {
					if ov.target == 2 && strings.compare(ov.property_path, "position") == 0 {
						on_disk_has_pos = true
						break
					}
				}
				if on_disk_has_pos do break
			}
			engine.scene_file_destroy(&sf)
		}
		testing.expect(t, on_disk_has_pos, "saved file should contain the position override on local_id=2")
	}

	// Reload from disk so the override comes through the same path the editor
	// uses when re-entering a saved scene. _scene_load_single unloads `loaded`.
	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc_mem.scene = reloaded

	host_c2 := find_transform_named(&tc_mem.world, reloaded, "TestC", false)
	transform_c_h2 := find_nested_named_under_host(&tc_mem.world, reloaded, host_c2, "TransformC")
	testing.expect(t, host_c2 != {} && transform_c_h2 != {})
	if host_c2 == {} || transform_c_h2 == {} do return

	t_c2 := engine.pool_get(&tc_mem.world.transforms, engine.Handle(transform_c_h2))
	testing.expect(t, t_c2 != nil)
	if t_c2 == nil do return
	testing.expect_value(t, t_c2.position, [3]f32{99, 99, 99})

	// The position override lives on whichever NestedScene record diffed
	// against TestC's prefab — that's the inner record (TestB-instance hosts
	// TestC, so the diff vs TestC.scene yields the override). Find it.
	owning_ns: ^engine.NestedScene
	for &ns_iter in reloaded.nested_scenes {
		for ov in ns_iter.overrides {
			if ov.target == 2 && strings.compare(ov.property_path, "position") == 0 {
				owning_ns = &ns_iter
				break
			}
		}
		if owning_ns != nil do break
	}
	testing.expect(t, owning_ns != nil, "expected some NestedScene to own the position override after reload")
	if owning_ns == nil do return

	engine.nested_scene_revert_override(owning_ns, 2, "position")

	for ov in owning_ns.overrides {
		testing.expect(t, !(ov.target == 2 && strings.compare(ov.property_path, "position") == 0),
			"override should be removed after revert")
	}

	// TransformC's base position in TestC.scene is {7, 8, 9}.
	testing.expect_value(t, t_c2.position, [3]f32{7, 8, 9})
}

@(test)
test_save_nested_b_to_c_writes_overrides_for_modified_c :: proc(t: ^testing.T) {
	engine.asset_db_init("moonhug/tests/fixtures/nested_scenes")
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()

	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_nested_bc_override.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	loaded := engine.scene_load_single_path("moonhug/tests/fixtures/nested_scenes/TestA.scene")
	testing.expect(t, loaded != nil, "TestA load failed")
	if loaded == nil do return
	tc_mem.scene = loaded

	guid_c, guid_err := uuid.read("ee7d67e6-2c06-41a5-a1f2-3b021b642202")
	testing.expect(t, guid_err == nil)
	if guid_err != nil do return
	guid_asset := engine.Asset_GUID(guid_c)

	host_b := find_transform_named(&tc_mem.world, loaded, "TestB", false)
	transform_c_h := find_nested_named_under_host(&tc_mem.world, loaded, host_b, "TransformC")
	testing.expect(t, host_b != {} && transform_c_h != {}, "expected TestB host and nested TransformC")
	if host_b == {} || transform_c_h == {} do return

	t_c := engine.pool_get(&tc_mem.world.transforms, engine.Handle(transform_c_h))
	testing.expect(t, t_c != nil)
	if t_c == nil do return
	want_pos := [3]f32{10.25, 20.5, 30.75}
	t_c.position = want_pos

	ok := engine.scene_save(loaded, tc_mem.path)
	testing.expect(t, ok, "scene_save failed")
	if !ok do return

	// On disk: the deep override should be persisted on the outer TestB NS as
	// a breadcrumb-backed entry. We expect (a) a breadcrumb pointing at
	// (TestC GUID, local_id=2), and (b) an override on a TestB-source-prefab
	// NS whose target is the breadcrumb's local_id and whose value matches
	// the change.
	sf, file_ok := engine.scene_file_load(tc_mem.path)
	testing.expect(t, file_ok)
	if !file_ok do return
	defer engine.scene_file_destroy(&sf)

	bc_lid := engine.Local_ID(0)
	for bc in sf.breadcrumbs {
		if bc.scene_source.guid == guid_asset && bc.scene_source.local_id == 2 {
			bc_lid = bc.local_id
			break
		}
	}
	testing.expect(t, bc_lid != 0,
		"saved file should contain a breadcrumb pointing to (TestC GUID, local_id=2)")

	deep_ok := false
	for ns in sf.nested_scenes {
		for ov in ns.overrides {
			if ov.target != bc_lid do continue
			if strings.compare(ov.property_path, "position") != 0 do continue
			if override_vec3_matches(ov.value, want_pos) {
				deep_ok = true
				break
			}
		}
		if deep_ok do break
	}
	testing.expect(t, deep_ok,
		"saved file should contain a deep override on the outer NS using the breadcrumb-backed target")

	// Round-trip: reload the saved file and verify TransformC's position is
	// the edited value, not TestC.scene's base value.
	reloaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, reloaded != nil, "reload after save failed")
	if reloaded == nil do return
	tc_mem.scene = reloaded

	host_b2 := find_transform_named(&tc_mem.world, reloaded, "TestB", false)
	tc_h2 := find_nested_named_under_host(&tc_mem.world, reloaded, host_b2, "TransformC")
	testing.expect(t, host_b2 != {} && tc_h2 != {}, "expected TestB+TransformC after reload")
	if host_b2 == {} || tc_h2 == {} do return

	t_c2 := engine.pool_get(&tc_mem.world.transforms, engine.Handle(tc_h2))
	testing.expect(t, t_c2 != nil)
	if t_c2 == nil do return
	testing.expect_value(t, t_c2.position, want_pos)
}
