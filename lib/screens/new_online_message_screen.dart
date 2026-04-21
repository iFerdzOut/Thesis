import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../services/contact_chat_service.dart';
import '../services/online_chat_service.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';

class NewOnlineMessageScreen extends StatefulWidget {
  const NewOnlineMessageScreen({super.key});

  @override
  State<NewOnlineMessageScreen> createState() => _NewOnlineMessageScreenState();
}

class _NewOnlineMessageScreenState extends State<NewOnlineMessageScreen> {
  final TextEditingController _searchController = TextEditingController();
  final ContactChatService contactChatService = ContactChatService();
  final OnlineChatService onlineChatService = OnlineChatService();
  String _searchQuery = '';

  static const Color _bgColor = Color(0xFF0B1622);
  static const Color _headerColor = Color(0xFF0E1A28);
  static const Color _accentColor = Color(0xFF25D366);

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: _headerColor,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'New Message',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
      body: Column(
        children: [
          Container(
            color: _headerColor,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Row(
              children: [
                const Text(
                  'To: ',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    cursorColor: _accentColor,
                    onChanged: (val) =>
                        setState(() => _searchQuery = val.trim().toLowerCase()),
                    decoration: const InputDecoration(
                      hintText: 'Type a name',
                      hintStyle: TextStyle(color: Colors.white38),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: contactChatService.getMyContacts(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(color: _accentColor),
                  );
                }

                final friends = snapshot.data!.docs.where((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  final name = (data['name']?.toString() ?? '').toLowerCase();
                  return name.contains(_searchQuery);
                }).toList();

                if (friends.isEmpty) {
                  return const Center(
                    child: Text('No friends found.',
                        style: TextStyle(color: Colors.white54)),
                  );
                }

                return ListView.builder(
                  itemCount: friends.length,
                  itemBuilder: (context, index) {
                    final data = friends[index].data() as Map<String, dynamic>;
                    final uid = data['uid'] ?? friends[index].id;
                    final name = data['name'] ?? 'Unknown User';

                    return StreamBuilder<DocumentSnapshot>(
                      stream: onlineChatService.getUserStatus(uid),
                      builder: (context, presenceSnap) {
                        String? photoUrl;
                        if (presenceSnap.hasData && presenceSnap.data!.exists) {
                          final pData = presenceSnap.data!.data()
                              as Map<String, dynamic>?;
                          photoUrl = pData?['photoUrl']?.toString();
                        }

                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          leading: UserAvatar(
                            name: name,
                            imageUrl: photoUrl,
                            radius: 24,
                            backgroundColor: Colors.white12,
                            foregroundColor: Colors.white,
                          ),
                          title: Text(name,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16)),
                          onTap: () {
                            // Use pushReplacement so going back from Chat goes to the Inbox, not this search screen again
                            Navigator.pushReplacement(
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
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}