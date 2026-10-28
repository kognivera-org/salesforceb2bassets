/**
 * Server side of the B2B storefront Product Compare feature.
 * Settings and attributes come from Custom Metadata; product data, entitlements and
 * buyer pricing come from the Commerce Connect API for the buyer's effective account.
 */
public with sharing class ProductCompareController {
    private static final String DEFAULT_SETTING = 'Default';
    private static final Integer DEFAULT_MAX_PRODUCTS = 4;
    private static final String DEFAULT_LIST_NAME = 'My Compare List';
    private static final String MODE_CATEGORY = 'Category';
    private static final String LEVEL_TOP = 'Top';
    private static final Integer DEFAULT_RECOMMENDATIONS = 4;

    private static ProductCompareCommerceGateway gateway = new ProductCompareCommerceGateway();

    @AuraEnabled(cacheable=true)
    public static CompareConfig getConfig(String webstoreId) {
        Product_Compare_Setting__mdt setting = findSetting(webstoreId);
        CompareConfig config = new CompareConfig();
        config.enabled = setting != null && setting.Enabled__c;
        config.maxProducts = maxProducts(setting);
        config.showAvailability =
            (setting != null && String.isNotBlank(setting.Availability_Field__c)) || findInventorySource(webstoreId) != null;
        config.attributes = getAttributes();
        config.categoryMode = isCategoryMode(setting);
        return config;
    }

    /**
     * Category mode: checks whether a product shares the compare category of the products already selected.
     * When it doesn't, suggests entitled products from the compare category. Global mode always allows.
     */
    @AuraEnabled
    public static CategoryCheck checkCategory(
        String webstoreId,
        String effectiveAccountId,
        String productId,
        List<String> selectedIds
    ) {
        Product_Compare_Setting__mdt setting = requireEnabled(webstoreId);
        CategoryCheck check = new CategoryCheck();
        check.allowed = true;
        List<String> ids = sanitizeIds(new List<String>{ productId }, 1);
        if (!isCategoryMode(setting) || ids.isEmpty()) {
            return check;
        }
        String newId = ids[0];
        // Selected products already share one category, so the first one stands for all of them.
        List<String> selected = sanitizeIds(selectedIds, 1);
        if (selected.isEmpty() || selected[0] == newId) {
            return check;
        }

        Map<String, List<ProductCompareCommerceGateway.CategoryNode>> paths;
        try {
            paths = gateway.getCategoryPaths(webstoreId, new List<String>{ newId, selected[0] });
        } catch (Exception e) {
            // Without category data the rule can't be applied; don't block the buyer.
            return check;
        }
        List<ProductCompareCommerceGateway.CategoryNode> comparePath = paths.get(selected[0]);
        ProductCompareCommerceGateway.CategoryNode compareCategory = categoryAt(comparePath, setting.Category_Level__c);
        ProductCompareCommerceGateway.CategoryNode newCategory = categoryAt(paths.get(newId), setting.Category_Level__c);
        String compareKey = compareCategory == null ? null : compareCategory.id;
        String newKey = newCategory == null ? null : newCategory.id;
        if (compareKey == newKey) {
            return check;
        }

        check.allowed = false;
        check.categoryName = compareCategory == null ? null : compareCategory.name;
        if (compareCategory != null && setting.Show_Recommendations__c == true) {
            Set<String> exclude = new Set<String>(sanitizeIds(selectedIds, 200));
            exclude.add(newId);
            // Most relevant first: the selected product's own category, then the rest of the compare category.
            List<String> searchOrder = new List<String>{ comparePath[comparePath.size() - 1].id };
            if (searchOrder[0] != compareCategory.id) {
                searchOrder.add(compareCategory.id);
            }
            check.suggestions = suggest(webstoreId, effectiveAccountId, searchOrder, exclude, recommendationCount(setting));
        }
        return check;
    }

    /** The compare category of the selected products (category mode), for display in the tray. */
    @AuraEnabled
    public static String getCompareCategoryName(String webstoreId, String productId) {
        Product_Compare_Setting__mdt setting = requireEnabled(webstoreId);
        List<String> ids = sanitizeIds(new List<String>{ productId }, 1);
        if (!isCategoryMode(setting) || ids.isEmpty()) {
            return null;
        }
        try {
            ProductCompareCommerceGateway.CategoryNode category = categoryAt(
                gateway.getCategoryPaths(webstoreId, ids).get(ids[0]),
                setting.Category_Level__c
            );
            return category == null ? null : category.name;
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * Picks the category products must share from a top-down category path.
     * Level: blank or Lowest = the product's own category, Top = top level, a number = depth from the top.
     */
    private static ProductCompareCommerceGateway.CategoryNode categoryAt(
        List<ProductCompareCommerceGateway.CategoryNode> path,
        String level
    ) {
        if (path == null || path.isEmpty()) {
            return null;
        }
        String value = level == null ? '' : level.trim();
        if (value.equalsIgnoreCase(LEVEL_TOP)) {
            return path[0];
        }
        if (value.isNumeric() && Integer.valueOf(value) >= 1) {
            return path[Math.min(Integer.valueOf(value), path.size()) - 1];
        }
        return path[path.size() - 1];
    }

    private static List<Suggestion> suggest(
        String webstoreId,
        String effectiveAccountId,
        List<String> categoryIds,
        Set<String> exclude,
        Integer count
    ) {
        List<Suggestion> suggestions = new List<Suggestion>();
        Set<String> seen = new Set<String>(exclude);
        for (String categoryId : categoryIds) {
            ConnectApi.ProductSearchResults results;
            try {
                results = gateway.searchCategory(webstoreId, effectiveAccountId, categoryId, count + exclude.size());
            } catch (Exception e) {
                continue;
            }
            if (results == null || results.productsPage == null || results.productsPage.products == null) {
                continue;
            }
            for (ConnectApi.ProductSummary summary : results.productsPage.products) {
                String id = summary == null ? null : toId(summary.id);
                if (id == null || seen.contains(id)) {
                    continue;
                }
                seen.add(id);
                Suggestion suggestion = new Suggestion();
                suggestion.id = id;
                suggestion.name = summary.name;
                suggestion.imageUrl = summary.defaultImage != null ? summary.defaultImage.url : null;
                suggestion.unitPrice = summary.prices != null ? toDecimal(summary.prices.unitPrice) : null;
                suggestion.currencyIsoCode = String.isNotBlank(results.productsPage.currencyIsoCode)
                    ? results.productsPage.currencyIsoCode
                    : UserInfo.getDefaultCurrency();
                suggestions.add(suggestion);
                if (suggestions.size() == count) {
                    return suggestions;
                }
            }
        }
        return suggestions;
    }

    private static Boolean isCategoryMode(Product_Compare_Setting__mdt setting) {
        return setting != null && setting.Compare_Mode__c == MODE_CATEGORY;
    }

    private static Integer recommendationCount(Product_Compare_Setting__mdt setting) {
        if (setting.Recommendation_Count__c == null || setting.Recommendation_Count__c < 1) {
            return DEFAULT_RECOMMENDATIONS;
        }
        return setting.Recommendation_Count__c.intValue();
    }

    /**
     * Returns compare data for the requested products, in the requested order.
     * Products the buyer is not entitled to are left out.
     */
    @AuraEnabled
    public static List<CompareProduct> getCompareData(
        String webstoreId,
        String effectiveAccountId,
        List<String> productIds
    ) {
        Product_Compare_Setting__mdt setting = requireEnabled(webstoreId);
        List<String> ids = sanitizeIds(productIds, maxProducts(setting));
        if (ids.isEmpty()) {
            return new List<CompareProduct>();
        }

        List<AttributeDef> attributes = getAttributes();
        Set<String> fields = new Set<String>{ 'Name' };
        for (AttributeDef attribute : attributes) {
            fields.add(attribute.fieldName);
        }
        String availabilityField = setting.Availability_Field__c;
        if (String.isNotBlank(availabilityField)) {
            fields.add(availabilityField);
        }

        ConnectApi.ProductOverviewCollection result;
        try {
            result = gateway.getProducts(webstoreId, effectiveAccountId, ids, new List<String>(fields));
        } catch (Exception e) {
            throw new AuraHandledException('Unable to load products for comparison. ' + e.getMessage());
        }

        Map<String, CompareProduct> productsById = new Map<String, CompareProduct>();
        if (result != null && result.products != null) {
            for (ConnectApi.ProductOverview overview : result.products) {
                // Products the buyer is not entitled to come back unsuccessful.
                if (overview == null || overview.success != true || toId(overview.id) == null) {
                    continue;
                }
                CompareProduct product = toCompareProduct(overview, attributes, availabilityField);
                productsById.put(product.id, product);
            }
        }
        if (!productsById.isEmpty()) {
            applyMissingFields(productsById.values(), attributes, availabilityField);
            applyPrices(webstoreId, effectiveAccountId, productsById);
            applyInventory(webstoreId, productsById.values());
        }

        List<CompareProduct> ordered = new List<CompareProduct>();
        for (String id : ids) {
            CompareProduct product = productsById.get(id);
            if (product != null) {
                ordered.add(product);
            }
        }
        return ordered;
    }

    /**
     * The catalog API returns text fields only, so picklist and checkbox attributes (e.g. Family) come back empty.
     * Those are read from Product2 for the already-entitled products. A lookup failure leaves the values blank.
     */
    private static void applyMissingFields(List<CompareProduct> products, List<AttributeDef> attributes, String availabilityField) {
        Set<String> missing = new Set<String>();
        for (CompareProduct product : products) {
            for (AttributeDef attribute : attributes) {
                if (String.isBlank(product.attributeValues.get(attribute.fieldName))) {
                    missing.add(attribute.fieldName);
                }
            }
            if (String.isNotBlank(availabilityField) && String.isBlank(product.availability)) {
                missing.add(availabilityField);
            }
        }
        if (missing.isEmpty()) {
            return;
        }
        List<String> ids = new List<String>();
        for (CompareProduct product : products) {
            ids.add(product.id);
        }
        Map<String, Map<String, String>> valuesById;
        try {
            valuesById = gateway.getFieldValues(ids, new List<String>(missing));
        } catch (Exception e) {
            return;
        }
        for (CompareProduct product : products) {
            Map<String, String> values = lowerCaseKeys(valuesById.get(product.id));
            for (AttributeDef attribute : attributes) {
                if (String.isBlank(product.attributeValues.get(attribute.fieldName))) {
                    product.attributeValues.put(attribute.fieldName, values.get(attribute.fieldName.toLowerCase()));
                }
            }
            if (String.isNotBlank(availabilityField) && String.isBlank(product.availability)) {
                product.availability = values.get(availabilityField.trim().toLowerCase());
            }
        }
    }

    /** Field names in metadata may differ in case from the Product2 field names. */
    private static Map<String, String> lowerCaseKeys(Map<String, String> values) {
        Map<String, String> result = new Map<String, String>();
        if (values != null) {
            for (String key : values.keySet()) {
                result.put(key.toLowerCase(), values.get(key));
            }
        }
        return result;
    }

    /** Adds buyer-specific prices. A pricing failure leaves prices blank rather than failing the comparison. */
    private static void applyPrices(String webstoreId, String effectiveAccountId, Map<String, CompareProduct> productsById) {
        ConnectApi.PricingResult pricing;
        try {
            pricing = gateway.getPrices(webstoreId, effectiveAccountId, new List<String>(productsById.keySet()));
        } catch (Exception e) {
            return;
        }
        if (pricing == null || pricing.pricingLineItemResults == null) {
            return;
        }
        for (ConnectApi.PricingResultLineItem line : pricing.pricingLineItemResults) {
            CompareProduct product = line == null ? null : productsById.get(toId(line.productId));
            if (product == null || line.success == false) {
                continue;
            }
            product.unitPrice = toDecimal(line.unitPrice);
            product.listPrice = toDecimal(line.listPrice);
            if (String.isNotBlank(pricing.currencyIsoCode)) {
                product.currencyIsoCode = pricing.currencyIsoCode;
            }
        }
    }

    /**
     * Sets stock status from the store's Omnichannel Inventory location group, the same source the
     * product page uses. SKUs with no inventory record count as out of stock. Stores without an
     * inventory source keep the Availability Field value; an inventory error leaves status unknown.
     */
    private static void applyInventory(String webstoreId, List<CompareProduct> products) {
        ProductCompareCommerceGateway.InventorySource source = findInventorySource(webstoreId);
        if (source == null) {
            return;
        }
        Map<String, List<CompareProduct>> productsBySku = new Map<String, List<CompareProduct>>();
        for (CompareProduct product : products) {
            if (String.isBlank(product.sku)) {
                continue;
            }
            if (!productsBySku.containsKey(product.sku)) {
                productsBySku.put(product.sku, new List<CompareProduct>());
            }
            productsBySku.get(product.sku).add(product);
        }
        if (productsBySku.isEmpty()) {
            return;
        }

        ConnectApi.OCIGetInventoryAvailabilityOutputRepresentation result;
        try {
            result = gateway.getInventory(source.locationGroup, new List<String>(productsBySku.keySet()));
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Product compare inventory lookup failed: ' + e.getTypeName() + ': ' + e.getMessage());
            return;
        }

        Map<String, Double> quantityBySku = new Map<String, Double>();
        if (result != null && result.locationGroups != null) {
            for (ConnectApi.OCILocationGroupAvailabilityOutputRepresentation locationGroup : result.locationGroups) {
                if (locationGroup.inventoryRecords == null) {
                    continue;
                }
                for (ConnectApi.OCIInventoryRecordOutputRepresentation record : locationGroup.inventoryRecords) {
                    Double quantity = source.useOnHand ? record.onHand : record.availableToOrder;
                    quantityBySku.put(record.stockKeepingUnit, quantity == null ? 0 : quantity);
                }
            }
        }
        for (String sku : productsBySku.keySet()) {
            Double quantity = quantityBySku.containsKey(sku) ? quantityBySku.get(sku) : 0;
            for (CompareProduct product : productsBySku.get(sku)) {
                product.inStock = quantity > 0;
                product.availability = product.inStock ? 'In stock' : 'Out of stock';
            }
        }
    }

    private static ProductCompareCommerceGateway.InventorySource findInventorySource(String webstoreId) {
        if (String.isBlank(webstoreId)) {
            return null;
        }
        try {
            return gateway.getInventorySource(webstoreId);
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * Adds a product to the buyer's first wishlist, creating one if none exists.
     */
    @AuraEnabled
    public static void addToList(String webstoreId, String effectiveAccountId, String productId) {
        requireEnabled(webstoreId);
        List<String> ids = sanitizeIds(new List<String>{ productId }, 1);
        if (ids.isEmpty()) {
            throw new AuraHandledException('Invalid product.');
        }
        // Only entitled products may be added.
        if (getCompareData(webstoreId, effectiveAccountId, ids).isEmpty()) {
            throw new AuraHandledException('This product is not available.');
        }
        try {
            ConnectApi.WishlistsSummary summary = gateway.getWishlists(webstoreId, effectiveAccountId);
            if (summary != null && summary.summaries != null && !summary.summaries.isEmpty()) {
                gateway.addToWishlist(webstoreId, effectiveAccountId, summary.summaries[0].id, ids[0]);
            } else {
                gateway.createWishlist(webstoreId, effectiveAccountId, DEFAULT_LIST_NAME, ids[0]);
            }
        } catch (Exception e) {
            throw new AuraHandledException('Unable to add the product to your list. ' + e.getMessage());
        }
    }

    private static CompareProduct toCompareProduct(
        ConnectApi.ProductOverview overview,
        List<AttributeDef> attributes,
        String availabilityField
    ) {
        Map<String, String> values = overview.fields != null ? overview.fields : new Map<String, String>();
        CompareProduct product = new CompareProduct();
        product.id = toId(overview.id);
        product.sku = overview.sku;
        product.name = values.get('Name');
        product.imageUrl = overview.defaultImage != null ? overview.defaultImage.url : null;
        product.currencyIsoCode = UserInfo.getDefaultCurrency();
        product.availability = String.isNotBlank(availabilityField) ? values.get(availabilityField) : null;
        product.attributeValues = new Map<String, String>();
        for (AttributeDef attribute : attributes) {
            product.attributeValues.put(attribute.fieldName, values.get(attribute.fieldName));
        }
        return product;
    }

    private static Product_Compare_Setting__mdt requireEnabled(String webstoreId) {
        Product_Compare_Setting__mdt setting = findSetting(webstoreId);
        if (setting == null || !setting.Enabled__c) {
            throw new AuraHandledException('Product compare is not enabled.');
        }
        return setting;
    }

    private static Product_Compare_Setting__mdt findSetting(String webstoreId) {
        Product_Compare_Setting__mdt fallback;
        for (Product_Compare_Setting__mdt setting : [
            SELECT DeveloperName, Enabled__c, Max_Products__c, WebStore_Id__c, Availability_Field__c,
                Compare_Mode__c, Category_Level__c, Show_Recommendations__c, Recommendation_Count__c
            FROM Product_Compare_Setting__mdt
        ]) {
            if (String.isNotBlank(webstoreId) && String.isNotBlank(setting.WebStore_Id__c) && sameId(setting.WebStore_Id__c, webstoreId)) {
                return setting;
            }
            if (setting.DeveloperName == DEFAULT_SETTING) {
                fallback = setting;
            }
        }
        return fallback;
    }

    private static List<AttributeDef> getAttributes() {
        List<Product_Compare_Attribute__mdt> records = [
            SELECT Field_API_Name__c, Label__c, Display_Order__c
            FROM Product_Compare_Attribute__mdt
            WHERE Active__c = TRUE
            ORDER BY Display_Order__c ASC NULLS LAST
        ];
        List<AttributeDef> attributes = new List<AttributeDef>();
        for (Product_Compare_Attribute__mdt record : records) {
            if (String.isBlank(record.Field_API_Name__c)) {
                continue;
            }
            AttributeDef attribute = new AttributeDef();
            attribute.fieldName = record.Field_API_Name__c.trim();
            attribute.label = String.isNotBlank(record.Label__c) ? record.Label__c : attribute.fieldName;
            attributes.add(attribute);
        }
        return attributes;
    }

    private static Integer maxProducts(Product_Compare_Setting__mdt setting) {
        if (setting == null || setting.Max_Products__c == null || setting.Max_Products__c < 2) {
            return DEFAULT_MAX_PRODUCTS;
        }
        return setting.Max_Products__c.intValue();
    }

    /** Keeps only valid, unique Product2 Ids, capped at the compare limit. */
    private static List<String> sanitizeIds(List<String> productIds, Integer max) {
        List<String> ids = new List<String>();
        if (productIds == null) {
            return ids;
        }
        Set<Id> seen = new Set<Id>();
        for (String raw : productIds) {
            Id productId;
            try {
                productId = Id.valueOf(raw);
            } catch (Exception e) {
                continue;
            }
            if (productId.getSObjectType() != Product2.SObjectType || seen.contains(productId)) {
                continue;
            }
            seen.add(productId);
            ids.add(productId);
            if (ids.size() == max) {
                break;
            }
        }
        return ids;
    }

    private static Boolean sameId(String a, String b) {
        try {
            return Id.valueOf(a) == Id.valueOf(b);
        } catch (Exception e) {
            return a == b;
        }
    }

    /** Normalizes a 15- or 18-character Id to its 18-character form; null if invalid. */
    private static String toId(String value) {
        try {
            return String.isBlank(value) ? null : String.valueOf(Id.valueOf(value));
        } catch (Exception e) {
            return null;
        }
    }

    private static Decimal toDecimal(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return Decimal.valueOf(value);
        } catch (Exception e) {
            return null;
        }
    }

    public class CompareConfig {
        @AuraEnabled
        public Boolean enabled;
        @AuraEnabled
        public Integer maxProducts;
        @AuraEnabled
        public Boolean showAvailability;
        @AuraEnabled
        public List<AttributeDef> attributes;
        /** True when only products from the same category can be compared. */
        @AuraEnabled
        public Boolean categoryMode;
    }

    public class CategoryCheck {
        @AuraEnabled
        public Boolean allowed;
        /** Name of the compare category, when the product is blocked. */
        @AuraEnabled
        public String categoryName;
        @AuraEnabled
        public List<Suggestion> suggestions;
    }

    public class Suggestion {
        @AuraEnabled
        public String id;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String imageUrl;
        @AuraEnabled
        public Decimal unitPrice;
        @AuraEnabled
        public String currencyIsoCode;
    }

    public class AttributeDef {
        @AuraEnabled
        public String fieldName;
        @AuraEnabled
        public String label;
    }

    public class CompareProduct {
        @AuraEnabled
        public String id;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String sku;
        @AuraEnabled
        public String imageUrl;
        @AuraEnabled
        public Decimal unitPrice;
        @AuraEnabled
        public Decimal listPrice;
        @AuraEnabled
        public String currencyIsoCode;
        @AuraEnabled
        public String availability;
        /** False when inventory shows no stock; null when the store has no inventory data. */
        @AuraEnabled
        public Boolean inStock;
        @AuraEnabled
        public Map<String, String> attributeValues;
    }
}
