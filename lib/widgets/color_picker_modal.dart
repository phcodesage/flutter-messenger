import 'package:flutter/material.dart';

/// Full-screen color picker modal for selecting and sending colors to chat partner
class ColorPickerModal extends StatefulWidget {
  final Function(Color) onColorSelected;
  
  const ColorPickerModal({
    super.key,
    required this.onColorSelected,
  });

  @override
  State<ColorPickerModal> createState() => _ColorPickerModalState();
}

class _ColorPickerModalState extends State<ColorPickerModal> {
  Color? _selectedColor;
  
  // Color palette with vibrant colors
  static const List<Color> _colorPalette = [
    // Row 1
    Color(0xFFFF6B6B), // Red/Coral
    Color(0xFF4ECDC4), // Turquoise
    Color(0xFF45B7D1), // Sky Blue
    Color(0xFFFF6BCB), // Hot Pink
    Color(0xFFFECA57), // Yellow
    
    // Row 2
    Color(0xFF00D2FF), // Cyan
    Color(0xFFFF00FF), // Magenta
    Color(0xFF00FFA3), // Mint Green
    Color(0xFF9D4EDD), // Purple
    Color(0xFFFFB347), // Orange
    
    // Row 3
    Color(0xFF1E1E1E), // Dark Gray (default)
    Color(0xFF3B82F6), // Blue
    Color(0xFFA855F7), // Purple
    Color(0xFF10B981), // Green
    Color(0xFFEF4444), // Red
    
    // Row 4
    Color(0xFFF59E0B), // Amber
    Color(0xFF14B8A6), // Teal
    Color(0xFF8B5CF6), // Violet
    Color(0xFFEC4899), // Pink
    Color(0xFF06B6D4), // Cyan Blue
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: const Color(0xFF2D2D2D),
      child: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Choose Color',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white, size: 28),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            
            const SizedBox(height: 20),
            
            // Selected color indicator
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                _selectedColor == null 
                    ? 'No color selected' 
                    : 'Color selected',
                style: TextStyle(
                  color: Colors.grey[400],
                  fontSize: 16,
                ),
              ),
            ),
            
            const SizedBox(height: 20),
            
            // Color swatches grid
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                    childAspectRatio: 1,
                  ),
                  itemCount: _colorPalette.length,
                  itemBuilder: (context, index) {
                    final color = _colorPalette[index];
                    final isSelected = _selectedColor?.value == color.value;
                    
                    return GestureDetector(
                      onTap: () {
                        setState(() {
                          _selectedColor = color;
                        });
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isSelected ? Colors.white : Colors.transparent,
                            width: 4,
                          ),
                          boxShadow: isSelected
                              ? [
                                  BoxShadow(
                                    color: color.withOpacity(0.5),
                                    blurRadius: 12,
                                    spreadRadius: 2,
                                  ),
                                ]
                              : [],
                        ),
                        child: isSelected
                            ? const Icon(
                                Icons.check,
                                color: Colors.white,
                                size: 32,
                              )
                            : null,
                      ),
                    );
                  },
                ),
              ),
            ),
            
            const SizedBox(height: 20),
            
            // Action buttons
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  // Cancel button
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4A4A4A),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  
                  const SizedBox(width: 16),
                  
                  // Send Color button
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: _selectedColor == null
                          ? null
                          : () {
                              widget.onColorSelected(_selectedColor!);
                              Navigator.pop(context);
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF8B5CF6),
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: const Color(0xFF4A4A4A),
                        disabledForegroundColor: Colors.grey[600],
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Send Color',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
