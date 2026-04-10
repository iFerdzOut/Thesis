import 'package:flutter/material.dart';
import 'chat_screen.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final TextEditingController searchController = TextEditingController();

  final List<Map<String, dynamic>> chats = [
    {
      "name": "John Doe",
      "phone": "09123456789",
      "lastMessage": "Hello!",
      "time": "9:45 AM",
      "unread": 2,
    },
    {
      "name": "Jane Smith",
      "phone": "09987654321",
      "lastMessage": "Are you available later?",
      "time": "8:10 AM",
      "unread": 0,
    },
    {
      "name": "Mark",
      "phone": "09111111111",
      "lastMessage": "Send me the file",
      "time": "Yesterday",
      "unread": 1,
    },
    {
      "name": "Unknown Number",
      "phone": "09000000000",
      "lastMessage": "Click this link to verify your account",
      "time": "Mon",
      "unread": 3,
    },
  ];

  String searchText = "";

  @override
  Widget build(BuildContext context) {
    final filteredChats = chats.where((chat) {
      final name = chat["name"].toString().toLowerCase();
      final message = chat["lastMessage"].toString().toLowerCase();
      final query = searchText.toLowerCase();

      return name.contains(query) || message.contains(query);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF075E54),
        title: const Text(
          "Chats",
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          IconButton(
            onPressed: () {},
            icon: const Icon(Icons.archive_outlined, color: Colors.white),
          ),
          IconButton(
            onPressed: () {},
            icon: const Icon(Icons.more_vert, color: Colors.white),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: TextField(
              controller: searchController,
              onChanged: (value) {
                setState(() {
                  searchText = value;
                });
              },
              decoration: InputDecoration(
                hintText: "Search chats",
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: const Color(0xFFF2F2F2),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(25),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: filteredChats.isEmpty
                ? const Center(
                    child: Text("No chats found."),
                  )
                : ListView.separated(
                    itemCount: filteredChats.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final chat = filteredChats[index];

                      return ListTile(
                        leading: const CircleAvatar(
                          radius: 24,
                          child: Icon(Icons.person),
                        ),
                        title: Text(
                          chat["name"],
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          chat["lastMessage"],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              chat["time"],
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                            const SizedBox(height: 6),
                            if (chat["unread"] > 0)
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: const BoxDecoration(
                                  color: Color(0xFF25D366),
                                  shape: BoxShape.circle,
                                ),
                                child: Text(
                                  chat["unread"].toString(),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ChatScreen(
                                contactName: chat["name"],
                                phone: chat["phone"],
                                chatType: "sms",
                              ),
                            ),
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