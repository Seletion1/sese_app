import 'package:sese_core/sese_core.dart';

/// "Other" sentinel appended to every dropdown — selecting it expands a
/// free-text field for custom details.
const String otherOption = 'Other';

/// Vehicle groups driving make/model catalogs.
enum VehicleCatalogGroup { motor, bike, cycle }

VehicleCatalogGroup catalogGroupFor(VehicleCategory category) {
  switch (category) {
    case VehicleCategory.bicycle:
      return VehicleCatalogGroup.cycle;
    case VehicleCategory.motorcycle:
    case VehicleCategory.tricycle:
      return VehicleCatalogGroup.bike;
    case VehicleCategory.car:
    case VehicleCategory.van:
    case VehicleCategory.truck:
      return VehicleCatalogGroup.motor;
  }
}

/// Makes per catalog group (spec lists, each plus "Other" at render time).
const Map<VehicleCatalogGroup, List<String>> catalogMakes = {
  VehicleCatalogGroup.motor: [
    'Toyota',
    'Honda',
    'Hyundai',
    'Kia',
    'Nissan',
    'Lexus',
    'Mercedes-Benz',
    'Volkswagen',
    'Peugeot',
  ],
  VehicleCatalogGroup.bike: [
    'Bajaj',
    'TVS',
    'Honda',
    'Haojue',
    'Daylong',
    'Piaggio',
    'Jincheng',
  ],
  VehicleCatalogGroup.cycle: [
    'Phoenix',
    'Trinx',
    'Giant',
    'Trek',
    "B'Twin",
  ],
};

/// Contextual models per make (plus "Other" at render time). Makes absent
/// here fall back to free text.
const Map<String, List<String>> catalogModels = {
  // Cars / vans / trucks
  'Toyota': ['Corolla', 'Camry', 'RAV4', 'Hilux', 'Hiace', 'Land Cruiser'],
  'Honda': ['Civic', 'Accord', 'CR-V', 'City'],
  'Hyundai': ['Elantra', 'Sonata', 'Tucson', 'Accent'],
  'Kia': ['Cerato', 'Rio', 'Sportage', 'Sorento'],
  'Nissan': ['Altima', 'Sentra', 'Sunny', 'Patrol'],
  'Lexus': ['ES', 'RX', 'LX'],
  'Mercedes-Benz': ['C-Class', 'E-Class', 'Sprinter'],
  'Volkswagen': ['Jetta', 'Passat', 'Transporter'],
  'Peugeot': ['301', '308', 'Boxer'],
  // Motorcycles / keke
  'Bajaj': ['Pulsar 220', 'Boxer 125', 'Qute (Keke)', 'RE (Keke)'],
  'TVS': ['HLX 125', 'HLX 150', 'King Deluxe (Keke)'],
  'Haojue': ['DK125', 'TF125'],
  'Daylong': ['DY125', 'DY150'],
  'Piaggio': ['Ape (Keke)'],
  'Jincheng': ['JC125', 'JC150'],
  // Bicycles
  'Phoenix': ['Road 700C', 'City 26"'],
  'Trinx': ['M116 26"', 'Tempo 700C'],
  'Giant': ['Escape 3', 'Talon 29"'],
  'Trek': ['Marlin 5', 'FX 2'],
  "B'Twin": ['Riverside 500', 'Triban RC 100'],
};

/// Shared color palette (plus "Other" at render time).
const List<String> catalogColors = [
  'Black',
  'White',
  'Silver',
  'Grey',
  'Blue',
  'Red',
  'Yellow',
  'Green',
  'Orange',
  'Gold',
  'Brown',
];

/// Manufacture years from the current year down to 1995.
List<int> catalogYears({int minYear = 1995}) {
  final current = DateTime.now().year;
  return [for (var y = current; y >= minYear; y--) y];
}
