import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/contact_chat_service.dart';
import '../services/user_profile_service.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';

class ContactsScreen extends StatefulWidget {
  final int initialTabIndex;

  const ContactsScreen({
    super.key,
    this.initialTabIndex = 0,
  });

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController searchController = TextEditingController();
  final ContactChatService contactChatService = ContactChatService();

  late final TabController _tabController;
  String searchText = '';
  static const Color _bgColor = Color(0xFF07131D);
  static const Color _surfaceColor = Color(0xFF10212E);
  static const Color _surfaceElevatedColor = Color(0xFF132837);
  static const Color _headerColor = Color(0xFF075E54);
  static const Color _accentColor = Color(0xFF25D366);
  static const Color _textPrimary = Color(0xFFF5FAFF);
  static const Color _textMuted = Color(0xFF93A4B5);

  String get currentUserId => FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    final initialIndex = widget.initialTabIndex.clamp(0, 1);
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: initialIndex,
    );
  }

  @override
  void dispose() {
    searchController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  String _normalize(String value) => value.trim().toLowerCase();

  bool _matchesQuery(List<String> values) {
    final query = _normalize(searchText);
    if (query.isEmpty) return true;
    return values.any((value) => _normalize(value).contains(query));
  }

  Future<void> _sendFriendRequest({
    required String uid,
    required String name,
    required String email,
  }) async {
    try {
      await contactChatService.sendFriendRequest(
        targetUid: uid,
        targetName: name,
        targetEmail: email,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Friend request sent to $name')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send request: $e')),
      );
    }
  }

  Future<void> _acceptFriendRequest({
    required String uid,
    required String name,
    required String email,
  }) async {
    try {
      await contactChatService.acceptFriendRequest(
        requesterUid: uid,
        requesterName: name,
        requesterEmail: email,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$name is now your friend')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to accept request: $e')),
      );
    }
  }

  Future<void> _declineFriendRequest(String uid) async {
    try {
      await contactChatService.declineFriendRequest(requesterUid: uid);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Friend request declined')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to decline request: $e')),
      );
    }
  }

  Future<void> _unfriend({
    required String uid,
    required String name,
  }) async {
    try {
      await contactChatService.unfriend(uid);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Removed $name from friends')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to remove friend: $e')),
      );
    }
  }

  void _openOnlineChat({
    required String uid,
    required String name,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          contactName: name,
          phone: '',
          chatType: 'online',
          receiverId: uid,
        ),
      ),
    );
  }

  Widget _buildFriendsTab() {
    return StreamBuilder<QuerySnapshot>(
      stream: contactChatService.getMyContacts(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text('Failed to load friends'));
        }

        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final friends = snapshot.data!.docs.where((doc) {
          final data = doc.data() as Map<String, dynamic>;
          return _matchesQuery([
            data['name']?.toString() ?? '',
            data['email']?.toString() ?? '',
          ]);
        }).toList();

        if (friends.isEmpty) {
          return const Center(
            child: Text(
              'No online friends yet. Add someone from Add People.',
              style: TextStyle(color: _textMuted),
            ),
          );
        }

        return ListView.separated(
          key: const PageStorageKey<String>('contacts_friends_list'),
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 18),
          itemCount: friends.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final data = friends[index].data() as Map<String, dynamic>;
            final uid = data['uid']?.toString() ?? '';
            final fallbackName = data['name']?.toString() ?? 'Unknown User';

            return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(uid)
                  .snapshots(),
              builder: (context, profileSnapshot) {
                final profileData = profileSnapshot.data?.data();
                final liveName = UserProfileService.resolveDisplayName(
                  data: profileData,
                  fallback: fallbackName,
                );
                final photoUrl = profileData?['photoUrl']?.toString();

                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(22),
                    onTap: () => _openOnlineChat(uid: uid, name: liveName),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: _surfaceColor,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: Colors.white10),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x26000000),
                            blurRadius: 16,
                            offset: Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          UserAvatar(name: liveName, imageUrl: photoUrl),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  liveName,
                                  style: const TextStyle(
                                    color: _textPrimary,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 17,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                const Text(
                                  'Friend ready for encrypted chat',
                                  style: TextStyle(
                                    color: _textMuted,
                                    fontSize: 12.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          PopupMenuButton<String>(
                            color: _surfaceElevatedColor,
                            onSelected: (value) {
                              if (value == 'chat') {
                                _openOnlineChat(uid: uid, name: liveName);
                              } else if (value == 'unfriend') {
                                _unfriend(uid: uid, name: liveName);
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'chat',
                                child: Text(
                                  'Open Chat',
                                  style: TextStyle(color: Colors.white),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'unfriend',
                                child: Text(
                                  'Unfriend',
                                  style: TextStyle(color: Colors.white),
                                ),
                              ),
                            ],
                            icon: const Icon(
                              Icons.more_horiz,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildPeopleTab() {
    return StreamBuilder<QuerySnapshot>(
      stream: contactChatService.searchAllUsers(),
      builder: (context, usersSnapshot) {
        if (usersSnapshot.hasError) {
          return const Center(child: Text('Failed to load people'));
        }

        if (!usersSnapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        return StreamBuilder<QuerySnapshot>(
          stream: contactChatService.getMyContacts(),
          builder: (context, friendsSnapshot) {
            final friendIds = friendsSnapshot.hasData
                ? friendsSnapshot.data!.docs
                    .map((doc) => (doc.data() as Map<String, dynamic>)['uid'])
                    .whereType<String>()
                    .toSet()
                : <String>{};

            return StreamBuilder<QuerySnapshot>(
              stream: contactChatService.getIncomingFriendRequests(),
              builder: (context, incomingSnapshot) {
                final incomingRequests = <String, Map<String, dynamic>>{};
                if (incomingSnapshot.hasData) {
                  for (final doc in incomingSnapshot.data!.docs) {
                    incomingRequests[doc.id] =
                        doc.data() as Map<String, dynamic>;
                  }
                }

                return StreamBuilder<QuerySnapshot>(
                  stream: contactChatService.getSentFriendRequests(),
                  builder: (context, sentSnapshot) {
                    final sentIds = sentSnapshot.hasData
                        ? sentSnapshot.data!.docs.map((doc) => doc.id).toSet()
                        : <String>{};

                    final users = usersSnapshot.data!.docs.where((doc) {
                      final data = doc.data() as Map<String, dynamic>;
                      final uid = data['uid']?.toString() ?? '';
                      final name = data['name']?.toString() ?? '';
                      final email = data['email']?.toString() ?? '';

                      if (uid.isEmpty || uid == currentUserId) {
                        return false;
                      }

                      return _matchesQuery([name, email]);
                    }).toList();

                    if (users.isEmpty) {
                      return const Center(
                        child: Text(
                          'No online users found.',
                          style: TextStyle(color: _textMuted),
                        ),
                      );
                    }

                    return ListView.separated(
                      key: const PageStorageKey<String>('contacts_people_list'),
                      physics: const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(),
                      ),
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 18),
                      itemCount: users.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final data =
                            users[index].data() as Map<String, dynamic>;
                        final uid = data['uid']?.toString() ?? '';
                        final name = data['name']?.toString() ?? 'Unknown User';
                        final email = data['email']?.toString() ?? '';

                        Widget trailing;
                        if (friendIds.contains(uid)) {
                          trailing = OutlinedButton(
                            onPressed: () =>
                                _openOnlineChat(uid: uid, name: name),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Colors.white24),
                            ),
                            child: const Text('Chat'),
                          );
                        } else if (incomingRequests.containsKey(uid)) {
                          trailing = Wrap(
                            spacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              TextButton(
                                onPressed: () => _declineFriendRequest(uid),
                                child: const Text('Decline'),
                              ),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _headerColor,
                                ),
                                onPressed: () => _acceptFriendRequest(
                                  uid: uid,
                                  name: name,
                                  email: email,
                                ),
                                child: const Text(
                                  'Accept',
                                  style: TextStyle(color: Colors.white),
                                ),
                              ),
                            ],
                          );
                        } else if (sentIds.contains(uid)) {
                          trailing = Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: _accentColor.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: _accentColor.withValues(alpha: 0.45),
                              ),
                            ),
                            child: const Text(
                              'Requested',
                              style: TextStyle(
                                color: Color(0xFFE8FFF1),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          );
                        } else {
                          trailing = ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _accentColor,
                            ),
                            onPressed: () => _sendFriendRequest(
                              uid: uid,
                              name: name,
                              email: email,
                            ),
                            child: const Text(
                              'Add Friend',
                              style: TextStyle(color: Colors.white),
                            ),
                          );
                        }

                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 14,
                          ),
                          decoration: BoxDecoration(
                            color: _surfaceColor,
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(color: Colors.white10),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x26000000),
                                blurRadius: 16,
                                offset: Offset(0, 10),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              UserAvatar(
                                name: name,
                                imageUrl: data['photoUrl']?.toString(),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      name,
                                      style: const TextStyle(
                                        color: _textPrimary,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 17,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      incomingRequests.containsKey(uid)
                                          ? 'Wants to connect with you'
                                          : sentIds.contains(uid)
                                              ? 'Friend request sent'
                                              : 'Registered app user',
                                      style: TextStyle(
                                        color: sentIds.contains(uid)
                                            ? const Color(0xFFBDECCD)
                                            : _textMuted,
                                        fontSize: 12.5,
                                        fontWeight: sentIds.contains(uid)
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              Flexible(child: trailing),
                            ],
                          ),
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: _headerColor,
        title: const Text(
          'Online Contacts',
          style: TextStyle(color: Colors.white),
        ),
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: _accentColor,
          indicatorWeight: 3,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: const [
            Tab(text: 'Friends'),
            Tab(text: 'Add People'),
          ],
        ),
      ),
      body: Column(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  _headerColor,
                  _bgColor,
                ],
              ),
            ),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: TextField(
              controller: searchController,
              onChanged: (value) {
                setState(() {
                  searchText = value;
                });
              },
              style: const TextStyle(color: Colors.white),
              cursorColor: _accentColor,
              decoration: InputDecoration(
                hintText: 'Search online friends or app users',
                hintStyle: const TextStyle(color: Colors.white54),
                prefixIcon: const Icon(Icons.search, color: Colors.white70),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          AnimatedBuilder(
            animation: _tabController,
            builder: (context, _) {
              return Container(
                width: double.infinity,
                color: _bgColor,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  _tabController.index == 0
                      ? 'Friends ready for online chat and calls'
                      : 'Find registered app users and build your circle',
                  style: const TextStyle(
                    color: _textMuted,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              );
            },
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildFriendsTab(),
                _buildPeopleTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
