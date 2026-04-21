import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../services/contact_chat_service.dart';
import '../services/online_chat_service.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';

class FriendsManagementScreen extends StatefulWidget {
  final int initialTabIndex;

  const FriendsManagementScreen({super.key, this.initialTabIndex = 0});

  @override
  State<FriendsManagementScreen> createState() => _FriendsManagementScreenState();
}

class _FriendsManagementScreenState extends State<FriendsManagementScreen> {
  static const Color _bgColor = Color(0xFF0B1622);
  static const Color _surfaceColor = Color(0xFF101C2B);
  static const Color _accentColor = Color(0xFF25D366);
  static const Color _headerColor = Color(0xFF0E1A28);
  static const Color _inputFillColor = Color(0xFF1A2737);

  final ContactChatService contactChatService = ContactChatService();
  final OnlineChatService onlineChatService = OnlineChatService();
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      initialIndex: widget.initialTabIndex,
      child: Scaffold(
        backgroundColor: _bgColor,
        appBar: AppBar(
          backgroundColor: _headerColor,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
          title: const Text(
            'Manage Friends',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          bottom: const TabBar(
            isScrollable: false,
            labelPadding: EdgeInsets.symmetric(horizontal: 2),
            labelStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            unselectedLabelStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            indicatorColor: _accentColor,
            labelColor: _accentColor,
            unselectedLabelColor: Colors.white54,
            dividerColor: Colors.transparent,
            tabs: [
              Tab(text: 'Online'),
              Tab(text: 'All'),
              Tab(text: 'Pending'),
              Tab(text: 'Blocked'),
              Tab(text: 'Add Friend'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildOnlineTab(),
            _buildAllFriendsTab(),
            _buildPendingTab(),
            _buildBlockedTab(),
            _buildAddFriendTab(),
          ],
        ),
      ),
    );
  }

  Widget _buildOnlineTab() {
    return StreamBuilder<QuerySnapshot>(
      stream: contactChatService.getMyContacts(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator(color: _accentColor));
        }
        
        final docs = snapshot.data!.docs;
        if (docs.isEmpty) {
          return _buildEmptyState(Icons.person_off_outlined, 'No friends online');
        }

        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final data = docs[index].data() as Map<String, dynamic>;
            final uid = data['uid'] ?? docs[index].id;
            final name = data['name'] ?? 'Unknown User';
            final photoUrl = data['photoUrl'];

            return StreamBuilder<DocumentSnapshot>(
              stream: onlineChatService.getUserStatus(uid),
              builder: (context, presenceSnap) {
                if (!presenceSnap.hasData || !presenceSnap.data!.exists) {
                  return const SizedBox.shrink();
                }
                
                final presenceData = presenceSnap.data!.data() as Map<String, dynamic>?;
                final isOnline = OnlineChatService.computeEffectiveOnline(presenceData);
                final presenceMode = OnlineChatService.normalizePresenceMode(presenceData?['presenceMode']?.toString());
                
                // Only show friends who are Online, Idle, or Do Not Disturb
                if (!isOnline && presenceMode != 'dnd' && presenceMode != 'idle') {
                  return const SizedBox.shrink();
                }

                return _buildFriendTile(
                  uid: uid, 
                  name: name, 
                  photoUrl: photoUrl, 
                  presenceMode: presenceMode, 
                  isOnline: isOnline,
                );
              }
            );
          },
        );
      },
    );
  }

  Widget _buildAllFriendsTab() {
    return StreamBuilder<QuerySnapshot>(
      stream: contactChatService.getMyContacts(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text('Error loading friends', style: TextStyle(color: Colors.white54)));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator(color: _accentColor));
        }

        final docs = snapshot.data!.docs;
        if (docs.isEmpty) {
          return _buildEmptyState(Icons.people_outline, 'No friends yet');
        }

        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final data = docs[index].data() as Map<String, dynamic>;
            final uid = data['uid'] ?? docs[index].id;
            final name = data['name'] ?? 'Unknown User';
            final photoUrl = data['photoUrl'];

            return _buildFriendTile(
              uid: uid, 
              name: name, 
              photoUrl: photoUrl,
              onLongPress: () => _showFriendOptionsModal(uid, name),
            );
          },
        );
      },
    );
  }

  Widget _buildPendingTab() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          alignment: Alignment.centerLeft,
          child: const Text('Incoming Requests', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: contactChatService.getIncomingFriendRequests(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: _accentColor));
              final docs = snapshot.data!.docs;
              if (docs.isEmpty) return _buildEmptyState(Icons.inbox, 'No incoming requests');
              
              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: docs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final data = docs[index].data() as Map<String, dynamic>;
                  final uid = data['uid'] ?? docs[index].id;
                  final senderName = data['name'] ?? data['displayName'] ?? 'Unknown';
                  final email = data['email']?.toString() ?? '';
                  
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _surfaceColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Row(
                      children: [
                        UserAvatar(name: senderName, radius: 24, backgroundColor: Colors.white12, foregroundColor: Colors.white),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(senderName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16)),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: _accentColor,
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () async {
                            await contactChatService.acceptFriendRequest(requesterUid: uid, requesterName: senderName, requesterEmail: email);
                            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Accepted request from $senderName')));
                          },
                          child: const Text('Accept', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.redAccent,
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () async {
                            await contactChatService.declineFriendRequest(requesterUid: uid);
                            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Declined request')));
                          },
                          child: const Text('Reject', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
        const Divider(color: Colors.white10, height: 1),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          alignment: Alignment.centerLeft,
          child: const Text('Sent Requests', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: contactChatService.getSentFriendRequests(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: _accentColor));
              final docs = snapshot.data!.docs;
              if (docs.isEmpty) return _buildEmptyState(Icons.outbox, 'No sent requests');
              
              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: docs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final data = docs[index].data() as Map<String, dynamic>;
                  final uid = data['uid'] ?? docs[index].id;
                  final targetName = data['name'] ?? data['displayName'] ?? 'Unknown';
                  
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _surfaceColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Row(
                      children: [
                        UserAvatar(name: targetName, radius: 24, backgroundColor: Colors.white12, foregroundColor: Colors.white),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(targetName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16)),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white54,
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () async {
                            await contactChatService.cancelFriendRequest(targetUid: uid);
                            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Canceled request')));
                          },
                          child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildBlockedTab() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: onlineChatService.getChatSettings(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: _accentColor));
        
        final blockedDocs = snapshot.data!.docs.where((doc) => doc.data()['blocked'] == true).toList();
        if (blockedDocs.isEmpty) return _buildEmptyState(Icons.block, 'No blocked users');
        
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: blockedDocs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final data = blockedDocs[index].data();
            final uid = blockedDocs[index].id;
            final name = data['name']?.toString() ?? 'Unknown User';
            
            return Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _surfaceColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                children: [
                  UserAvatar(name: name, radius: 24, backgroundColor: Colors.white12, foregroundColor: Colors.white),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16)),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: Colors.white10,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () async {
                      await onlineChatService.setConversationBlocked(otherUserId: uid, blocked: false, otherName: name);
                      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Unblocked $name')));
                    },
                    child: const Text('Unblock', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showFriendOptionsModal(String uid, String name) {
    showModalBottomSheet(
      context: context,
      backgroundColor: _surfaceColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetContext) {
        return SafeArea(
          child: Wrap(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text('Options for $name', style: const TextStyle(color: Colors.white54, fontSize: 13)),
              ),
              ListTile(
                leading: const Icon(Icons.person_remove_outlined, color: Colors.white),
                title: const Text('Unfriend', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _confirmUnfriend(uid, name);
                },
              ),
              ListTile(
                leading: const Icon(Icons.block, color: Colors.redAccent),
                title: const Text('Block User', style: TextStyle(color: Colors.redAccent)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _confirmBlock(uid, name);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _confirmUnfriend(String uid, String name) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _surfaceColor,
        title: Text('Unfriend $name?', style: const TextStyle(color: Colors.white)),
        content: Text('Are you sure you want to remove $name from your friends list?', style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              Navigator.pop(dialogContext);
              await contactChatService.unfriend(uid);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Unfriended $name')));
            },
            child: const Text('Unfriend', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _confirmBlock(String uid, String name) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _surfaceColor,
        title: Text('Block $name?', style: const TextStyle(color: Colors.white)),
        content: Text('Are you sure you want to block $name? They will be removed from your friends and won\'t be able to add or message you.', style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              Navigator.pop(dialogContext);
              await contactChatService.unfriend(uid);
              await onlineChatService.setConversationBlocked(otherUserId: uid, blocked: true, otherName: name);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Blocked $name')));
            },
            child: const Text('Block', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildAddFriendTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Add a friend by their Display Name', style: TextStyle(color: Colors.white70, fontSize: 14)),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: _inputFillColor,
              borderRadius: BorderRadius.circular(16),
            ),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Enter display name...',
                hintStyle: TextStyle(color: Colors.white54),
                prefixIcon: Icon(Icons.search, color: Colors.white54),
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              ),
              onSubmitted: (value) {
                setState((){});
              },
            ),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: _searchController.text.isEmpty
                ? const Center(child: Icon(Icons.person_search, size: 64, color: Colors.white10))
                : FutureBuilder<QuerySnapshot>(
                    future: FirebaseFirestore.instance
                        .collection('users')
                        .where('displayName', isGreaterThanOrEqualTo: _searchController.text)
                        .where('displayName', isLessThanOrEqualTo: '${_searchController.text}\uf8ff')
                        .get(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator(color: _accentColor));
                      }
                      if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                        return const Center(child: Text('No users found', style: TextStyle(color: Colors.white54)));
                      }

                      return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                        stream: onlineChatService.getChatSettings(),
                        builder: (context, settingsSnap) {
                          final blockedIds = settingsSnap.hasData 
                              ? settingsSnap.data!.docs.where((d) => d.data()['blocked'] == true).map((d) => d.id).toSet() 
                              : <String>{};

                          final docs = snapshot.data!.docs.where((d) => d.id != onlineChatService.currentUserId && !blockedIds.contains(d.id)).toList();
                          if (docs.isEmpty) {
                            return const Center(child: Text('No users found', style: TextStyle(color: Colors.white54)));
                          }
                          
                          return StreamBuilder<QuerySnapshot>(
                            stream: contactChatService.getSentFriendRequests(),
                            builder: (context, sentSnap) {
                              final sentIds = sentSnap.hasData ? sentSnap.data!.docs.map((d) => d.id).toSet() : <String>{};
                              
                              return StreamBuilder<QuerySnapshot>(
                                stream: contactChatService.getMyContacts(),
                                builder: (context, friendsSnap) {
                                  final friendIds = friendsSnap.hasData ? friendsSnap.data!.docs.map((d) => d.id).toSet() : <String>{};
                                  
                                  return ListView.separated(
                                    itemCount: docs.length,
                                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                                    itemBuilder: (context, index) {
                                      final data = docs[index].data() as Map<String, dynamic>;
                                      final uid = docs[index].id;
                                      final name = data['displayName'] ?? data['name'] ?? 'Unknown';
                                      final isSent = sentIds.contains(uid);
                                      final isFriend = friendIds.contains(uid);

                                      return ListTile(
                                        tileColor: _surfaceColor,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                        leading: UserAvatar(name: name, radius: 20, backgroundColor: Colors.white12, foregroundColor: Colors.white),
                                        title: Text(name, style: const TextStyle(color: Colors.white)),
                                        trailing: isFriend 
                                          ? const OutlinedButton(onPressed: null, child: Text('Friends'))
                                          : ElevatedButton(
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: isSent ? Colors.white10 : _accentColor,
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                          ),
                                          onPressed: isSent ? null : () async {
                                            try {
                                              await contactChatService.sendFriendRequest(
                                                targetUid: uid,
                                                targetName: name,
                                                targetEmail: data['email']?.toString() ?? '',
                                              );
                                              if (!context.mounted) return;
                                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Friend request sent to $name!')));
                                            } catch (e) {
                                              if (!context.mounted) return;
                                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to send request: $e')));
                                            }
                                          },
                                          child: Text(isSent ? 'Sent' : 'Add', style: TextStyle(color: isSent ? Colors.white54 : Colors.white)),
                                        ),
                                      );
                                    },
                                  );
                                }
                              );
                            }
                          );
                        }
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFriendTile({required String uid, required String name, String? photoUrl, String? presenceMode, bool? isOnline, VoidCallback? onLongPress}) {
    return GestureDetector(
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _surfaceColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            Stack(
            children: [
              UserAvatar(name: name, imageUrl: photoUrl, radius: 24, backgroundColor: Colors.white12, foregroundColor: Colors.white),
              if (presenceMode != null && isOnline != null)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: _presenceColor(presenceMode, isOnline),
                      shape: BoxShape.circle,
                      border: Border.all(color: _surfaceColor, width: 2),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16)),
          ),
          IconButton(
            icon: const Icon(Icons.chat_bubble_outline, color: _accentColor),
            onPressed: () {
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
            },
          ),
        ],
      ),
      ),
    );
  }

  Color _presenceColor(String mode, bool isOnline) {
    switch (mode) {
      case 'dnd': return Colors.redAccent;
      case 'idle': return Colors.amber;
      case 'invisible': return Colors.grey;
      case 'online':
      default: return isOnline ? _accentColor : Colors.grey;
    }
  }

  Widget _buildEmptyState(IconData icon, String text) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: Colors.white10),
          const SizedBox(height: 16),
          Text(text, style: const TextStyle(color: Colors.white54, fontSize: 16)),
        ],
      ),
    );
  }
}