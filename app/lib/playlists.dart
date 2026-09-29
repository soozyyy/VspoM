part of 'main.dart';

// Feature 6: user playlists. Several named playlists, each an ordered list
// of songs, built only from these pages (add songs one by one, or add every
// current song of a channel). Played shuffled, or in order via _inOrder.
//
// Stored as videoIds, never catalog indices: indices shift whenever the
// catalog gains songs. A videoId that's no longer in the catalog is hidden
// but kept, so the song comes back if it returns.

class Playlist {
  Playlist({required this.id, required this.name, required this.videoIds});

  final String id;
  String name;
  List<String> videoIds;

  factory Playlist.fromJson(Map<String, dynamic> json) => Playlist(
        id: json['id'] as String,
        name: json['name'] as String,
        videoIds: List<String>.from(json['videoIds'] as List<dynamic>),
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'videoIds': videoIds};
}

Future<File> _playlistsFile() async =>
    File('${(await getApplicationSupportDirectory()).path}/playlists.json');

Future<List<Playlist>> _loadPlaylists() async {
  try {
    final file = await _playlistsFile();
    if (!await file.exists()) return [];
    final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
    return decoded
        .map((e) => Playlist.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (_) {
    return [];
  }
}

// Saves run one after another, so two quick edits can't write the temp file
// at the same time. The JSON is taken now, so each save writes the state as
// of its own edit. Write-then-rename, like _saveCachedCatalog.
Future<void> _lastPlaylistSave = Future.value();

void _queueSavePlaylists(List<Playlist> playlists) {
  final body = jsonEncode(playlists);
  _lastPlaylistSave = _lastPlaylistSave.then((_) async {
    try {
      final file = await _playlistsFile();
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(body, flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // Disk error: the edit stays in memory, and the next edit saves again.
    }
  });
}

extension _Playlists on _PlaylistScreenState {
  Map<String, int> get _indexById =>
      {for (var i = 0; i < _catalog.length; i++) _catalog[i].videoId: i};

  // A playlist's songs as catalog indices, in playlist order, skipping
  // songs that aren't in the catalog right now.
  List<int> _playlistIndices(Playlist p) {
    final ids = _indexById;
    return [for (final id in p.videoIds) if (ids[id] != null) ids[id]!];
  }

  // Plays `indices` in this exact order from `start`, looping (see _inOrder
  // in _playSongAt). Any shuffle or Library tap turns _inOrder off again.
  Future<void> _playInOrder(List<int> indices, int start) async {
    if (_hasPermission != true) {
      await _requestPermission();
      return;
    }
    if (indices.isEmpty) return;
    _shuffleScope = null;
    _inOrder = true;
    _playOrder = List.of(indices);
    await _playSongAt(start);
  }

  Future<String?> _askName(String title, {String initial = ''}) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Playlist name'),
          onSubmitted: (v) => Navigator.of(c).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _newPlaylist() async {
    final name = await _askName('New playlist');
    if (name == null || name.isEmpty) return;
    final p = Playlist(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      videoIds: [],
    );
    _editPlaylists(() => _playlists.add(p));
    _openPlaylist(p);
  }

  void _openPlaylist(Playlist p) => _pushLive((c) => _buildPlaylist(c, p));

  // ---- Playlists tab (footer) ----

  Widget _buildPlaylistsTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Playlists',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              FilledButton.icon(
                onPressed:
                    (_playlistsLoaded && !_loadingCatalog) ? _newPlaylist : null,
                icon: const Icon(Icons.add),
                label: const Text('New playlist'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.deepPurple,
                ),
              ),
            ],
          ),
        ),
        if (_playlistsLoaded && _playlists.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
            child: Text(
              'No playlists yet. Tap New playlist to make one.',
              style: TextStyle(color: Colors.grey.shade500),
            ),
          ),
        for (final p in _playlists) _buildPlaylistRow(p),
      ],
    );
  }

  Widget _buildPlaylistRow(Playlist p) {
    final indices = _playlistIndices(p);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      leading: indices.isEmpty
          ? Container(
              width: 85,
              height: 48,
              decoration: BoxDecoration(
                color: Colors.grey.shade800,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Icon(Icons.queue_music, color: Colors.white38),
            )
          : _ThumbnailImage(
              url: _catalog[indices.first].thumbnailUrl,
              width: 85,
              height: 48,
            ),
      title: Text(
        p.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white),
      ),
      subtitle: Text(
        '${indices.length} songs',
        style: TextStyle(color: Colors.grey.shade400, fontSize: 12.5),
      ),
      onTap: () => _openPlaylist(p),
    );
  }

  // ---- One playlist ----

  Widget _buildPlaylist(BuildContext routeContext, Playlist p) {
    final indices = _playlistIndices(p);
    final song = _currentSong;
    return Scaffold(
      appBar: AppBar(
        title: Text(p.name),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'rename') {
                final name = await _askName('Rename playlist', initial: p.name);
                if (name != null && name.isNotEmpty) {
                  _editPlaylists(() => p.name = name);
                }
              } else {
                final ok = await showDialog<bool>(
                  context: routeContext,
                  builder: (c) => AlertDialog(
                    title: Text('Delete "${p.name}"?'),
                    content: const Text('The songs stay in your library.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(c).pop(false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(c).pop(true),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (ok == true) {
                  _editPlaylists(() => _playlists.remove(p));
                  if (routeContext.mounted) Navigator.of(routeContext).pop();
                }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(value: 'delete', child: Text('Delete playlist')),
            ],
          ),
        ],
      ),
      body: ReorderableListView.builder(
        // Own drag handle on the right; the default (long-press anywhere)
        // would fight with tap-to-play.
        buildDefaultDragHandles: false,
        padding: const EdgeInsets.only(bottom: 24),
        header: _buildPlaylistHeader(p, indices),
        itemCount: indices.length,
        onReorder: (from, to) {
          if (to > from) to -= 1;
          final order = List.of(indices);
          order.insert(to, order.removeAt(from));
          final shown = {for (final i in order) _catalog[i].videoId};
          _editPlaylists(() {
            // Hidden (not-in-catalog) songs keep their place at the end.
            p.videoIds = [
              for (final i in order) _catalog[i].videoId,
              for (final id in p.videoIds) if (!shown.contains(id)) id,
            ];
          });
        },
        itemBuilder: (context, i) => KeyedSubtree(
          key: ValueKey(_catalog[indices[i]].videoId),
          child: _buildTrackRow(
            indices[i],
            // Tap = play this playlist in order from here.
            onTap: () => _playInOrder(indices, i),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(Icons.close, color: Colors.grey.shade500),
                  tooltip: 'Remove',
                  onPressed: () => _editPlaylists(
                    () => p.videoIds.remove(_catalog[indices[i]].videoId),
                  ),
                ),
                ReorderableDragStartListener(
                  index: i,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(Icons.drag_handle, color: Colors.grey.shade500),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: song == null ? null : _buildMiniPlayer(song),
    );
  }

  Widget _buildPlaylistHeader(Playlist p, List<int> indices) {
    final empty = indices.isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${indices.length} songs',
            style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: empty ? null : () => _shufflePlayAll(scope: indices),
                  icon: const Icon(Icons.shuffle),
                  label: const Text('Shuffle'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: empty ? null : () => _playInOrder(indices, 0),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play in order'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _openAddSongs(p),
                  icon: const Icon(Icons.add),
                  label: const Text('Add songs'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pushLive((c) => _buildAddChannel(p)),
                  icon: const Icon(Icons.person_add_alt),
                  label: const Text('Add channel'),
                ),
              ),
            ],
          ),
          if (empty)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Text(
                'No songs yet.',
                style: TextStyle(color: Colors.grey.shade500),
              ),
            ),
        ],
      ),
    );
  }

  // ---- Add songs ----

  void _openAddSongs(Playlist p) {
    // Lives across the page's rebuilds (_pushLive re-runs the builder, this
    // closure's variable stays).
    var query = '';
    _pushLive(
      (c) => StatefulBuilder(
        builder: (c, setLocal) {
          final inList = p.videoIds.toSet();
          final matches = [
            for (var i = 0; i < _catalog.length; i++)
              if (_catalog[i].matchesSearch(query)) i,
          ];
          return Scaffold(
            appBar: AppBar(title: Text('Add to ${p.name}')),
            body: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: TextField(
                      onChanged: (v) => setLocal(() => query = v),
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Search songs or artists…',
                        hintStyle: TextStyle(color: Colors.grey.shade500),
                        prefixIcon:
                            Icon(Icons.search, color: Colors.grey.shade500),
                        filled: true,
                        fillColor: const Color(0xFF1E1E1E),
                        contentPadding: const EdgeInsets.symmetric(vertical: 0),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                ),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final id = _catalog[matches[i]].videoId;
                      final added = inList.contains(id);
                      // Tap the row or the icon: add, or remove if added.
                      void toggle() => _editPlaylists(() {
                            if (added) {
                              p.videoIds.remove(id);
                            } else {
                              p.videoIds.add(id);
                            }
                          });
                      return _buildTrackRow(
                        matches[i],
                        onTap: toggle,
                        trailing: IconButton(
                          icon: Icon(
                            added ? Icons.check_circle : Icons.add_circle_outline,
                            color: added
                                ? Colors.deepPurpleAccent
                                : Colors.grey.shade400,
                          ),
                          onPressed: toggle,
                        ),
                      );
                    },
                    childCount: matches.length,
                    addAutomaticKeepAlives: false,
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ),
          );
        },
      ),
    );
  }

  // ---- Add channel ----

  // Artists in debut order (the _artists getter). "Add all" appends every
  // song of theirs not already in the playlist: a one-time snapshot, so
  // their later songs don't appear on their own.
  Widget _buildAddChannel(Playlist p) {
    final inList = p.videoIds.toSet();
    final artists = _artists;
    return Scaffold(
      appBar: AppBar(title: Text('Add to ${p.name}')),
      body: ListView.builder(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: artists.length,
        itemBuilder: (context, i) {
          final name = artists[i].key;
          final indices = artists[i].value;
          final first = _catalog[indices.first];
          final missing = [
            for (final idx in indices)
              if (!inList.contains(_catalog[idx].videoId)) _catalog[idx].videoId,
          ];
          return ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            leading: _ThumbnailImage(
              url: first.artistAvatarUrl ?? first.thumbnailUrl,
              width: 48,
              height: 48,
              borderRadius: 24,
              errorIcon: Icons.person,
            ),
            title: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white),
            ),
            subtitle: Text(
              '${indices.length} songs',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 12.5),
            ),
            trailing: missing.isEmpty
                ? const TextButton(onPressed: null, child: Text('Added ✓'))
                : TextButton(
                    onPressed: () =>
                        _editPlaylists(() => p.videoIds.addAll(missing)),
                    child: const Text('Add all'),
                  ),
          );
        },
      ),
    );
  }
}
