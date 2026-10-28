/**
 * Thin wrapper around the Commerce Connect API used by ProductCompareController, so tests can substitute it.
 * Kept at API 63.0: ConnectApi.CommerceCatalog.getProducts is not available in later API versions.
 */
public with sharing virtual class ProductCompareCommerceGateway {
    /** Entitled product data for the buyer's account. Prices are fetched separately with getPrices. */
    public virtual ConnectApi.ProductOverviewCollection getProducts(
        String webstoreId,
        String effectiveAccountId,
        List<String> productIds,
        List<String> fields
    ) {
        return ConnectApi.CommerceCatalog.getProducts(webstoreId, effectiveAccountId, productIds, null, fields, false, true);
    }

    /** Buyer-specific prices from the store's price books. */
    public virtual ConnectApi.PricingResult getPrices(String webstoreId, String effectiveAccountId, List<String> productIds) {
        ConnectApi.PricingInput input = new ConnectApi.PricingInput();
        input.pricingLineItems = new List<ConnectApi.PricingLineItemInput>();
        for (String productId : productIds) {
            ConnectApi.PricingLineItemInput item = new ConnectApi.PricingLineItemInput();
            item.productId = productId;
            input.pricingLineItems.add(item);
        }
        return ConnectApi.CommerceStorePricing.getProductPrices(webstoreId, effectiveAccountId, input);
    }

    /** The store's enabled inventory source (Omnichannel Inventory location group), or null if it has none. */
    public virtual InventorySource getInventorySource(String webstoreId) {
        return new InventorySourceReader().read(webstoreId);
    }

    /** Live availability for the given SKUs in a location group. */
    public virtual ConnectApi.OCIGetInventoryAvailabilityOutputRepresentation getInventory(String locationGroup, List<String> skus) {
        ConnectApi.OCIGetInventoryAvailabilityInputRepresentation input = new ConnectApi.OCIGetInventoryAvailabilityInputRepresentation();
        input.locationGroupIdentifiers = new List<String>{ locationGroup };
        input.stockKeepingUnits = skus;
        input.useCache = true;
        return ConnectApi.OmnichannelInventoryService.getInventoryAvailability(input);
    }

    public virtual ConnectApi.WishlistsSummary getWishlists(String webstoreId, String effectiveAccountId) {
        return ConnectApi.CommerceWishlist.getWishlistSummaries(webstoreId, effectiveAccountId, false);
    }

    public virtual void addToWishlist(String webstoreId, String effectiveAccountId, String wishlistId, String productId) {
        ConnectApi.WishlistItemInput item = new ConnectApi.WishlistItemInput();
        item.productId = productId;
        ConnectApi.CommerceWishlist.addItemToWishlist(webstoreId, effectiveAccountId, wishlistId, item);
    }

    public virtual void createWishlist(String webstoreId, String effectiveAccountId, String name, String productId) {
        ConnectApi.WishlistItemInput item = new ConnectApi.WishlistItemInput();
        item.productId = productId;
        ConnectApi.WishlistInput input = new ConnectApi.WishlistInput();
        input.name = name;
        input.products = new List<ConnectApi.WishlistItemInput>{ item };
        ConnectApi.CommerceWishlist.createWishlist(webstoreId, effectiveAccountId, input);
    }

    /**
     * Category path of each product in the store's catalog, ordered from the top-level category down to the
     * product's primary category (or its first category when none is marked primary).
     */
    public virtual Map<String, List<CategoryNode>> getCategoryPaths(String webstoreId, List<String> productIds) {
        return new CategoryReader().read(webstoreId, productIds);
    }

    /** Entitled products in a category and its subcategories, with buyer prices. */
    public virtual ConnectApi.ProductSearchResults searchCategory(
        String webstoreId,
        String effectiveAccountId,
        String categoryId,
        Integer pageSize
    ) {
        ConnectApi.ProductSearchInput input = new ConnectApi.ProductSearchInput();
        input.categoryId = categoryId;
        input.pageSize = pageSize;
        input.includePrices = true;
        input.fields = new List<String>{ 'Name' };
        return ConnectApi.CommerceSearch.searchProducts(webstoreId, effectiveAccountId, input);
    }

    /**
     * Product2 field values keyed by product Id, then field API name. Used for fields the catalog API leaves out
     * (picklists, checkboxes). Callers pass only products the buyer is entitled to; fields the buyer can't read are dropped.
     */
    public virtual Map<String, Map<String, String>> getFieldValues(List<String> productIds, List<String> fields) {
        return new FieldReader().read(productIds, fields);
    }

    public class CategoryNode {
        public String id;
        public String name;
    }

    public class InventorySource {
        public String locationGroup;
        /** True when the store counts stock as on hand rather than available to order. */
        public Boolean useOnHand;
    }

    /** Store inventory configuration is admin data that buyers can't read, so it is read without sharing. */
    private without sharing class InventorySourceReader {
        InventorySource read(String webstoreId) {
            for (WebStoreInventorySource record : [
                SELECT LocationSourceExtRef, InventoryDimension
                FROM WebStoreInventorySource
                WHERE WebStoreId = :webstoreId AND IsEnabled = TRUE
                ORDER BY IsDefault DESC
            ]) {
                // LocationSourceExtRef can't be filtered in SOQL, so skip blank ones here.
                if (String.isBlank(record.LocationSourceExtRef)) {
                    continue;
                }
                InventorySource source = new InventorySource();
                source.locationGroup = record.LocationSourceExtRef;
                source.useOnHand = record.InventoryDimension == 'OnHand';
                return source;
            }
            return null;
        }
    }

    /**
     * Buyers see products through entitlement policies rather than record sharing, so records are read without sharing.
     * Field-level security still applies: stripInaccessible removes fields the buyer can't read.
     */
    private without sharing class FieldReader {
        Map<String, Map<String, String>> read(List<String> productIds, List<String> fields) {
            Map<String, Map<String, String>> values = new Map<String, Map<String, String>>();
            Map<String, Schema.SObjectField> productFields = Schema.SObjectType.Product2.fields.getMap();
            Set<String> valid = new Set<String>();
            for (String field : fields) {
                // Only real Product2 field names reach the query.
                if (String.isNotBlank(field) && productFields.containsKey(field.trim().toLowerCase())) {
                    valid.add(productFields.get(field.trim().toLowerCase()).getDescribe().getName());
                }
            }
            if (valid.isEmpty() || productIds == null || productIds.isEmpty()) {
                return values;
            }
            List<SObject> records = Database.query(
                'SELECT Id, ' + String.join(new List<String>(valid), ', ') + ' FROM Product2 WHERE Id IN :productIds'
            );
            for (SObject record : Security.stripInaccessible(AccessType.READABLE, records).getRecords()) {
                Map<String, Object> populated = record.getPopulatedFieldsAsMap();
                Map<String, String> row = new Map<String, String>();
                for (String field : valid) {
                    Object value = populated.get(field);
                    if (value != null) {
                        row.put(field, String.valueOf(value));
                    }
                }
                values.put(String.valueOf(record.Id), row);
            }
            return values;
        }
    }

    /**
     * Catalog structure is not buyer-specific and buyers may lack access to it, so it is read without sharing.
     * Entitlement is still enforced: suggested products come from the buyer's search.
     */
    private without sharing class CategoryReader {
        // B2B catalogs allow at most 5 category levels; the extra pass guards against bad data.
        private final Integer maxDepth = 6;

        Map<String, List<CategoryNode>> read(String webstoreId, List<String> productIds) {
            Map<String, List<CategoryNode>> paths = new Map<String, List<CategoryNode>>();
            Set<Id> catalogIds = new Set<Id>();
            for (WebStoreCatalog storeCatalog : [SELECT ProductCatalogId FROM WebStoreCatalog WHERE SalesStoreId = :webstoreId]) {
                catalogIds.add(storeCatalog.ProductCatalogId);
            }
            if (catalogIds.isEmpty() || productIds == null || productIds.isEmpty()) {
                return paths;
            }

            // Candidate categories per product: the primary one only when set, otherwise all of them.
            Map<String, List<Id>> candidatesByProduct = new Map<String, List<Id>>();
            Set<String> hasPrimary = new Set<String>();
            Set<Id> toLoad = new Set<Id>();
            for (ProductCategoryProduct link : [
                SELECT ProductId, ProductCategoryId, IsPrimaryCategory
                FROM ProductCategoryProduct
                WHERE ProductId IN :productIds AND ProductCategory.CatalogId IN :catalogIds
                ORDER BY IsPrimaryCategory DESC, CreatedDate ASC
            ]) {
                String productId = String.valueOf(link.ProductId);
                if (hasPrimary.contains(productId)) {
                    continue;
                }
                if (link.IsPrimaryCategory) {
                    hasPrimary.add(productId);
                }
                if (!candidatesByProduct.containsKey(productId)) {
                    candidatesByProduct.put(productId, new List<Id>());
                }
                candidatesByProduct.get(productId).add(link.ProductCategoryId);
                toLoad.add(link.ProductCategoryId);
            }

            Map<Id, ProductCategory> categories = new Map<Id, ProductCategory>();
            for (Integer depth = 0; depth < maxDepth && !toLoad.isEmpty(); depth++) {
                Set<Id> parents = new Set<Id>();
                for (ProductCategory category : [SELECT Id, Name, ParentCategoryId FROM ProductCategory WHERE Id IN :toLoad]) {
                    categories.put(category.Id, category);
                    if (category.ParentCategoryId != null && !categories.containsKey(category.ParentCategoryId)) {
                        parents.add(category.ParentCategoryId);
                    }
                }
                toLoad = parents;
            }

            // Without a primary category, the most specific (deepest) one is the most relevant; ties keep the oldest link.
            for (String productId : candidatesByProduct.keySet()) {
                List<CategoryNode> best = new List<CategoryNode>();
                for (Id categoryId : candidatesByProduct.get(productId)) {
                    List<CategoryNode> path = pathOf(categories, categoryId);
                    if (path.size() > best.size()) {
                        best = path;
                    }
                }
                paths.put(productId, best);
            }
            return paths;
        }

        private List<CategoryNode> pathOf(Map<Id, ProductCategory> categories, Id categoryId) {
            List<CategoryNode> upward = new List<CategoryNode>();
            ProductCategory category = categories.get(categoryId);
            while (category != null && upward.size() < maxDepth) {
                CategoryNode node = new CategoryNode();
                node.id = category.Id;
                node.name = category.Name;
                upward.add(node);
                category = category.ParentCategoryId == null ? null : categories.get(category.ParentCategoryId);
            }
            List<CategoryNode> path = new List<CategoryNode>();
            for (Integer i = upward.size() - 1; i >= 0; i--) {
                path.add(upward[i]);
            }
            return path;
        }
    }
}
